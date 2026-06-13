"""FastAPI app exposing /health, /api/text, /api/audio, /api/audio/{id}."""
from __future__ import annotations

import asyncio
import json
import logging
import secrets
from contextlib import asynccontextmanager, suppress
from typing import Annotated

from fastapi import (
    Depends,
    FastAPI,
    File,
    Form,
    Header,
    HTTPException,
    Request,
    Response,
    UploadFile,
)
from fastapi.responses import FileResponse, StreamingResponse

from . import mdns, schedules
from .approvals import ApprovalBroker
from .audio_store import AudioStore
from .config import Settings, get_settings
from .harness import HARNESS_DISPLAY_NAMES, HarnessClient
from .hermes import HermesClient, HermesError, MockHermesClient, StreamReply, StreamTool
from .models import (
    DeviceRegisterRequest,
    DeviceResponse,
    HarnessItem,
    HealthResponse,
    HistoryMessage,
    HistoryToolCall,
    ReplayRequest,
    ReplayResponse,
    ScheduleCreateRequest,
    ScheduleResponse,
    ScheduleUpdateRequest,
    SessionDetailResponse,
    SessionListItem,
    TextRequest,
    ToolCallSummary,
    TurnAnswer,
    TurnResponse,
    VoiceItem,
)
from .session_audit import fetch_tool_calls_since
from .sessions import get_session, list_sessions
from .speakable import make_speakable
from .stt import STTProvider, make_stt
from .tts import TTSProvider, make_tts

logger = logging.getLogger("hermes_voice")
logger.setLevel(logging.INFO)

# 25 MB cap on /api/audio uploads — well over any realistic short utterance.
MAX_AUDIO_BYTES = 25 * 1024 * 1024

# Strong refs to fire-and-forget background tasks (TTS stream producers) so the
# event loop doesn't garbage-collect — and thereby cancel — them mid-flight.
# Each is discarded from the set on completion.
_bg_tasks: set[asyncio.Task] = set()

# How long the streaming-TTS producer waits to hand off a chunk before deciding
# the consumer is gone (never connected, or disconnected). Past this it stops
# and closes the upstream connection rather than blocking on a full queue.
_STREAM_IDLE_TIMEOUT = 60.0


def _is_loopback_host(host: str) -> bool:
    """True when `host` only accepts local connections — so an empty auth token
    there is safe. Anything else (0.0.0.0, ::, a LAN/Tailscale IP) is exposed."""
    h = host.strip().lower()
    return h in {"localhost", "127.0.0.1", "::1"} or h.startswith("127.")


def assert_safe_bind(settings: Settings) -> None:
    """Fail closed before binding a socket: a non-loopback host with no auth
    token would expose every endpoint to anyone on the LAN/tailnet. Called from
    the server entrypoint (__main__), not app construction — TestClient builds
    the app without binding, so it must stay exempt."""
    if not settings.auth_token and not _is_loopback_host(settings.host):
        raise RuntimeError(
            f"refusing to start: host={settings.host!r} is not loopback and "
            "HERMES_VOICE_TOKEN is empty — set a token or bind to 127.0.0.1"
        )


def create_app(
    *,
    hermes: HarnessClient | None = None,
    stt: STTProvider | None = None,
    tts: TTSProvider | None = None,
    store: AudioStore | None = None,
) -> FastAPI:
    settings = get_settings()
    auto_mock = settings.mock or _should_auto_mock(settings)
    injected_hermes = hermes is not None

    if hermes is None:
        hermes = _make_hermes(settings, auto_mock)
    if stt is None:
        stt = make_stt(settings)
    if tts is None:
        tts = make_tts(settings)
    if store is None:
        store = AudioStore()

    # Init the schedules store synchronously here (cheap, sqlite3 only) so
    # CRUD endpoints work even before lifespan fires (TestClient doesn't run
    # lifespan unless used as a context manager).
    schedules._init_sync()

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        # Start the executor loop. It owns its own asyncio.Task and is
        # cancelled on shutdown.
        task = asyncio.create_task(schedules.executor_loop(app))
        # Warm-ACP: start the long-lived `hermes acp` child so turns skip the
        # per-turn cold-start. Guarded — only HermesAcpClient has start(); the
        # mock/legacy clients and injected test fakes don't, so it's a no-op for
        # them (and tests don't run the lifespan unless used as a context mgr).
        if not auto_mock and hasattr(app.state.hermes, "start"):
            try:
                await app.state.hermes.start()
            except Exception as e:
                logger.error("ACP server failed to start (turns will error): %s", e)
        # Advertise over Bonjour/mDNS so the iOS app can discover this backend
        # on the LAN. Best-effort: skipped in mock/dev mode, and a no-op on a
        # headless / no-LAN host. `scheme` matches how __main__ launches uvicorn.
        mdns_state = None
        if settings.bonjour_enabled and not auto_mock:
            scheme = "https" if (settings.ssl_certfile and settings.ssl_keyfile) else "http"
            mdns_state = await mdns.start_mdns(
                port=settings.port,
                scheme=scheme,
                public_host=settings.public_host,
            )
        try:
            yield
        finally:
            # Cancel the executor FIRST so a teardown error in mDNS can't orphan
            # it; then stop mDNS inside its own guard.
            task.cancel()
            try:
                await task
            except (asyncio.CancelledError, Exception):
                pass
            try:
                await mdns.stop_mdns(mdns_state)
            except Exception as e:
                logger.warning("mdns shutdown error: %s", e)
            # Cancel any live TTS producers + delete the temp audio dir so a
            # restart doesn't leak a `harness-voice-*` dir each time.
            try:
                store.close()
            except Exception as e:
                logger.warning("audio store shutdown error: %s", e)
            # Tear down the warm ACP child (no-op unless it was started).
            if hasattr(app.state.hermes, "aclose"):
                try:
                    await app.state.hermes.aclose()
                except Exception as e:
                    logger.warning("ACP shutdown error: %s", e)

    app = FastAPI(
        title="Hermes Voice Backend",
        version="0.1.0",
        lifespan=lifespan,
    )
    app.state.settings = settings
    app.state.hermes = hermes
    # Harness registry: the per-turn `harness` param routes to one of these.
    # P2 adds claude/codex/opencode; for now Hermes is the only backend.
    app.state.harnesses = {"hermes": hermes}
    # Register coding-agent adapters whose CLI is installed. Production only:
    # tests inject a fake hermes and must stay isolated from real subprocesses.
    if not injected_hermes:
        from .adapters import ADAPTER_CLASSES
        for hid, cls in ADAPTER_CLASSES.items():
            try:
                adapter = cls(settings)
                if adapter.is_available():
                    app.state.harnesses[hid] = adapter
            except Exception as e:
                logger.warning("harness adapter %s unavailable: %s", hid, e)
    app.state.default_harness = (
        settings.default_harness
        if settings.default_harness in app.state.harnesses
        else "hermes"
    )
    # Phase B: per-turn approval/question channel (voice-mediated tool approval).
    app.state.approvals = ApprovalBroker()
    app.state.stt = stt
    app.state.tts = tts
    app.state.store = store
    app.state.auto_mock = auto_mock

    _register_routes(app)
    return app


def _should_auto_mock(s: Settings) -> bool:
    """Engage mock mode if NO Hermes binary AND no API keys are configured.

    Keeps the dev loop friction-free: clone, `uv run`, open iOS, it just works.
    """
    import shutil
    has_hermes = shutil.which(s.hermes_bin) is not None
    has_any_key = bool(s.openai_key or s.groq_key or s.elevenlabs_key)
    return not (has_hermes or has_any_key)


def _make_hermes(settings: Settings, auto_mock: bool) -> HarnessClient:
    """Pick the default Hermes-backing client: mock in dev/test, the warm ACP
    server when HERMES_USE_ACP is set, else the legacy `hermes chat` subprocess
    (the fallback). ACP is imported lazily so the common path doesn't load it."""
    if auto_mock:
        return MockHermesClient(settings)
    if settings.use_acp:
        from .acp_client import HermesAcpClient
        return HermesAcpClient(settings)
    return HermesClient(settings)


def _token_ok(request: Request, token: str | None) -> bool:
    """True when the request is authenticated — or no token is configured (dev
    loopback). Shared by `_require_token` (hard gate) and `/health` (soft: it
    downgrades to a minimal body rather than 401)."""
    expected = request.app.state.settings.auth_token
    if not expected:
        return True
    return bool(token) and secrets.compare_digest(token, expected)


def _require_token(
    request: Request,
    x_hermes_voice_token: Annotated[str | None, Header()] = None,
) -> None:
    if not _token_ok(request, x_hermes_voice_token):
        raise HTTPException(status_code=401, detail="invalid or missing token")


def _register_routes(app: FastAPI) -> None:
    @app.get("/health", response_model=HealthResponse)
    async def health(
        request: Request,
        x_hermes_voice_token: Annotated[str | None, Header()] = None,
    ) -> HealthResponse:
        # Public, token-free: reachability for the onboarding connection test.
        base = HealthResponse(
            status="ok", mock=app.state.auto_mock, scheme=request.url.scheme
        )
        # Config details (binary paths, workspace dir, providers) only for an
        # authenticated caller — otherwise anyone on the tailnet/LAN could read
        # the runtime layout.
        if not _token_ok(request, x_hermes_voice_token):
            return base
        hermes: HermesClient = app.state.hermes
        stt: STTProvider | None = app.state.stt
        tts: TTSProvider | None = app.state.tts
        base.hermes = hermes.describe()
        base.stt = stt.describe() if stt else {"name": "none", "configured": False}
        base.tts = tts.describe() if tts else {"name": "none", "configured": False}
        return base

    @app.post(
        "/api/text",
        response_model=TurnResponse,
        dependencies=[Depends(_require_token)],
    )
    async def text_turn(body: TextRequest) -> TurnResponse:
        return await _run_turn(
            app,
            harness=_resolve_harness(app, body.harness),
            user_text=body.text,
            session_id=body.session_id,
            voice_id=body.voice_id,
            tts_mode=body.tts,
        )

    @app.post(
        "/api/audio",
        response_model=TurnResponse,
        dependencies=[Depends(_require_token)],
    )
    async def audio_turn(
        file: Annotated[UploadFile, File()],
        session_id: Annotated[str | None, Form()] = None,
        voice_id: Annotated[str | None, Form()] = None,
        tts: Annotated[str | None, Form()] = None,
        harness: Annotated[str | None, Form()] = None,
    ) -> TurnResponse:
        harness_client = _resolve_harness(app, harness)
        stt: STTProvider | None = app.state.stt
        if stt is None:
            raise HTTPException(
                status_code=503,
                detail=(
                    "No STT provider configured. Set OPENAI_API_KEY, GROQ_API_KEY, "
                    "install '.[local]' for faster-whisper, or use /api/text."
                ),
            )

        audio_bytes = await _read_capped(file, MAX_AUDIO_BYTES)
        try:
            user_text = await stt.transcribe(audio_bytes, mime=file.content_type)
        except Exception as e:
            logger.exception("STT failure")
            raise HTTPException(status_code=502, detail=f"transcription failed: {e}") from e

        if not user_text:
            raise HTTPException(status_code=422, detail="no speech detected")

        return await _run_turn(
            app, harness=harness_client,
            user_text=user_text, session_id=session_id, voice_id=voice_id, tts_mode=tts
        )

    @app.post("/api/text/stream", dependencies=[Depends(_require_token)])
    async def text_turn_stream(body: TextRequest) -> StreamingResponse:
        harness = _resolve_harness(app, body.harness)
        return StreamingResponse(
            _stream_turn(
                app,
                harness=harness,
                user_text=body.text,
                session_id=body.session_id,
                voice_id=body.voice_id,
                tts_mode=body.tts,
                mode=body.mode,
            ),
            media_type="text/event-stream",
            headers={"Cache-Control": "no-store", "X-Accel-Buffering": "no"},
        )

    @app.post("/api/audio/stream", dependencies=[Depends(_require_token)])
    async def audio_turn_stream(
        file: Annotated[UploadFile, File()],
        session_id: Annotated[str | None, Form()] = None,
        voice_id: Annotated[str | None, Form()] = None,
        tts: Annotated[str | None, Form()] = None,
        harness: Annotated[str | None, Form()] = None,
        mode: Annotated[str | None, Form()] = None,
    ) -> StreamingResponse:
        harness_client = _resolve_harness(app, harness)
        stt: STTProvider | None = app.state.stt
        if stt is None:
            raise HTTPException(status_code=503, detail="No STT provider configured.")
        audio_bytes = await _read_capped(file, MAX_AUDIO_BYTES)
        try:
            user_text = await stt.transcribe(audio_bytes, mime=file.content_type)
        except Exception as e:
            logger.exception("STT failure")
            raise HTTPException(status_code=502, detail=f"transcription failed: {e}") from e
        if not user_text:
            raise HTTPException(status_code=422, detail="no speech detected")
        return StreamingResponse(
            _stream_turn(
                app, harness=harness_client,
                user_text=user_text, session_id=session_id, voice_id=voice_id,
                tts_mode=tts, mode=mode,
            ),
            media_type="text/event-stream",
            headers={"Cache-Control": "no-store", "X-Accel-Buffering": "no"},
        )

    @app.get(
        "/api/sessions",
        response_model=list[SessionListItem],
        dependencies=[Depends(_require_token)],
    )
    async def list_session_history(
        limit: int = 30, source: str | None = None
    ) -> list[SessionListItem]:
        # Cap limit defensively so a misbehaving client can't ask for 100k.
        limit = max(1, min(limit, 200))
        items = await list_sessions(limit=limit, source=source)
        return [
            SessionListItem(
                session_id=s.id,
                source=s.source,
                started_at=s.started_at,
                message_count=s.message_count,
                tool_call_count=s.tool_call_count,
                preview=s.preview,
            )
            for s in items
        ]

    @app.get(
        "/api/sessions/{session_id}",
        response_model=SessionDetailResponse,
        dependencies=[Depends(_require_token)],
    )
    async def get_session_detail(session_id: str) -> SessionDetailResponse:
        # session_id is YYYYMMDD_HHMMSS_<hex>; lightly validate so we can't be
        # tricked into SQL-injection-via-LIKE or unusual paths.
        if not all(c.isalnum() or c == "_" for c in session_id):
            raise HTTPException(status_code=400, detail="bad session id")
        detail = await get_session(session_id)
        if detail is None:
            raise HTTPException(status_code=404, detail="session not found")

        messages: list[HistoryMessage] = []
        for m in detail.messages:
            tool_calls: list[HistoryToolCall] = []
            if m.tool_calls:
                for tc in m.tool_calls:
                    fn = (tc.get("function") or {})
                    name = fn.get("name") or "tool"
                    args = fn.get("arguments") or ""
                    if isinstance(args, str) and len(args) > 200:
                        args = args[:197] + "..."
                    tool_calls.append(HistoryToolCall(
                        name=name, arguments_preview=str(args), ok=None,
                    ))
            messages.append(HistoryMessage(
                role=m.role,
                text=m.content,
                timestamp=m.timestamp,
                tool_name=m.tool_name,
                tool_calls=tool_calls,
            ))

        return SessionDetailResponse(
            session_id=detail.id,
            source=detail.source,
            started_at=detail.started_at,
            title=detail.title,
            messages=messages,
        )

    @app.post(
        "/api/replay",
        response_model=ReplayResponse,
        dependencies=[Depends(_require_token)],
    )
    async def replay_audio(body: ReplayRequest) -> ReplayResponse:
        """Re-synthesize TTS for previously-spoken assistant text.

        Used by the iOS history view to replay any past assistant message.
        Costs whatever ElevenLabs charges for the text length — cheap for
        short confirmations, more for long explanations. Hermes is NOT
        re-invoked; this is pure TTS.
        """
        tts: TTSProvider | None = app.state.tts
        if tts is None:
            raise HTTPException(
                status_code=503, detail="No TTS provider configured."
            )
        try:
            # De-markdown the spoken copy here too: replay re-synthesizes the
            # RAW stored assistant text (history-tap sends message.text; the
            # scheduled-push auto-play sends the raw assistant_text), so without
            # this TTS would still read "##"/asterisks/code fences aloud. Idempotent.
            audio_url = _start_stream(app, tts, make_speakable(body.text), voice_id=body.voice_id)
        except Exception as e:
            logger.warning("replay tts error: %s", e)
            raise HTTPException(status_code=502, detail=f"tts failed: {e}") from e
        return ReplayResponse(audio_url=audio_url)

    @app.get(
        "/api/voices",
        response_model=list[VoiceItem],
        dependencies=[Depends(_require_token)],
    )
    async def list_voices() -> list[VoiceItem]:
        """Selectable TTS voices for the active provider (ElevenLabs only today).

        Returns [] for providers without a voice catalog (mock/openai/piper) so
        the iOS picker can just fall back to the server default.
        """
        tts: TTSProvider | None = app.state.tts
        fetch = getattr(tts, "list_voices", None)
        if tts is None or fetch is None:
            return []
        try:
            voices = await fetch()
        except Exception as e:
            logger.warning("voice list failed: %s", e)
            raise HTTPException(status_code=502, detail=f"voice list failed: {e}") from e
        return [VoiceItem(**v) for v in voices]

    @app.get(
        "/api/harnesses",
        response_model=list[HarnessItem],
        dependencies=[Depends(_require_token)],
    )
    async def list_harnesses() -> list[HarnessItem]:
        """Selectable agent backends for the iOS picker. `available` reflects
        whether each CLI is installed on the host."""
        harnesses: dict[str, HarnessClient] = app.state.harnesses
        items: list[HarnessItem] = []
        for hid, client in harnesses.items():
            try:
                avail = bool(client.is_available())
            except Exception:
                avail = False
            items.append(HarnessItem(
                id=hid,
                name=HARNESS_DISPLAY_NAMES.get(hid, hid.title()),
                available=avail,
            ))
        return items

    @app.get(
        "/api/harnesses/{harness_id}/sessions",
        response_model=list[SessionListItem],
        dependencies=[Depends(_require_token)],
    )
    async def list_harness_sessions(
        harness_id: str, limit: int = 30
    ) -> list[SessionListItem]:
        """Recent sessions for one harness, for the iOS 'attach' picker. An
        adapter without `list_sessions` lists nothing (same optional-capability
        pattern as /api/voices)."""
        harness = _resolve_harness(app, harness_id)
        fetch = getattr(harness, "list_sessions", None)
        if fetch is None:
            return []
        limit = max(1, min(limit, 200))
        try:
            sessions = await fetch(limit)
        except Exception as e:
            logger.warning("session list failed for %s: %s", harness_id, e)
            raise HTTPException(
                status_code=502, detail=f"session list failed: {e}"
            ) from e
        return [
            SessionListItem(
                session_id=s.session_id,
                source=s.source,
                started_at=s.started_at,
                message_count=s.message_count,
                tool_call_count=s.tool_call_count,
                preview=s.preview,
                cwd=s.cwd,
                title=s.title,
                size_bytes=s.size_bytes,
            )
            for s in sessions
        ]

    @app.post(
        "/api/turns/{turn_id}/answer",
        dependencies=[Depends(_require_token)],
    )
    async def answer_turn(turn_id: str, body: TurnAnswer) -> dict:
        """Answer a mid-turn approval/question (Phase B). The turn's agent
        permission callback is awaiting this; 404 if there's no pending request
        with that id (e.g. it already timed out or the turn ended)."""
        ok: bool = app.state.approvals.answer(turn_id, body.request_id, body.value)
        if not ok:
            raise HTTPException(status_code=404, detail="no such pending request")
        return {"ok": True}

    @app.get(
        "/api/schedules",
        response_model=list[ScheduleResponse],
        dependencies=[Depends(_require_token)],
    )
    async def list_schedules() -> list[ScheduleResponse]:
        items = await schedules.list_all()
        return [ScheduleResponse(**s.as_dict()) for s in items]

    @app.post(
        "/api/schedules",
        response_model=ScheduleResponse,
        dependencies=[Depends(_require_token)],
    )
    async def create_schedule(body: ScheduleCreateRequest) -> ScheduleResponse:
        s = await schedules.create(
            cadence_seconds=body.cadence_seconds,
            prompt=body.prompt,
            display_name=body.display_name,
        )
        return ScheduleResponse(**s.as_dict())

    @app.patch(
        "/api/schedules/{schedule_id}",
        response_model=ScheduleResponse,
        dependencies=[Depends(_require_token)],
    )
    async def update_schedule(
        schedule_id: str, body: ScheduleUpdateRequest
    ) -> ScheduleResponse:
        s = await schedules.update(
            schedule_id,
            cadence_seconds=body.cadence_seconds,
            prompt=body.prompt,
            display_name=body.display_name,
            enabled=body.enabled,
        )
        if s is None:
            raise HTTPException(status_code=404, detail="schedule not found")
        return ScheduleResponse(**s.as_dict())

    @app.delete(
        "/api/schedules/{schedule_id}",
        status_code=204,
        dependencies=[Depends(_require_token)],
    )
    async def delete_schedule(schedule_id: str) -> Response:
        ok = await schedules.delete(schedule_id)
        if not ok:
            raise HTTPException(status_code=404, detail="schedule not found")
        return Response(status_code=204)

    @app.post(
        "/api/devices",
        response_model=DeviceResponse,
        dependencies=[Depends(_require_token)],
    )
    async def register_device(body: DeviceRegisterRequest) -> DeviceResponse:
        d = await schedules.upsert_device(
            token=body.token,
            platform=body.platform,
            bundle_id=body.bundle_id,
            environment=body.environment,
        )
        return DeviceResponse(
            token=d.token, platform=d.platform, bundle_id=d.bundle_id,
            environment=d.environment, registered_at=d.registered_at,
            last_seen_at=d.last_seen_at,
        )

    @app.delete(
        "/api/devices/{token}",
        status_code=204,
        dependencies=[Depends(_require_token)],
    )
    async def unregister_device(token: str) -> Response:
        # Idempotent: returning 204 on already-missing tokens is fine.
        await schedules.delete_device(token)
        return Response(status_code=204)

    @app.get(
        "/api/audio/{audio_id}",
        dependencies=[Depends(_require_token)],
    )
    async def get_audio(audio_id: str) -> Response:
        if not audio_id.replace("-", "").replace("_", "").isalnum():
            raise HTTPException(status_code=400, detail="bad audio id")

        # Live-streaming path: TTS producer is currently pushing chunks.
        stream = app.state.store.get_stream(audio_id)
        if stream is not None:
            async def gen():
                async for chunk in app.state.store.iter_chunks(audio_id):
                    yield chunk
            return StreamingResponse(
                gen(),
                media_type=stream.mime,
                headers={
                    # Hint to AVPlayer that this is progressive media and to
                    # not try Range/byte-serving (we don't support that).
                    "Cache-Control": "no-store",
                    "Accept-Ranges": "none",
                },
            )

        # Completed-file path: synthesized in full, sitting on disk.
        path = app.state.store.path_for(audio_id)
        if path is None or not path.exists():
            raise HTTPException(status_code=404, detail="audio expired or unknown")
        media = "audio/mpeg" if path.suffix == ".mp3" else "audio/wav"
        return FileResponse(path, media_type=media)


def _start_stream(
    app: FastAPI, tts: TTSProvider, text: str, voice_id: str | None = None
) -> str:
    """Kick off a background streaming-TTS task and return the audio URL.

    The HTTP response can come back to iOS before any audio is synthesized;
    iOS hits the audio URL and reads chunks as ElevenLabs produces them.
    """
    store: AudioStore = app.state.store
    audio_id, queue = store.start_stream(tts.stream_extension, tts.stream_mime)

    async def producer() -> None:
        gen = tts.stream(text, voice_id=voice_id)
        try:
            # wait_for() so a consumer that never connects (or stalls) can't
            # block the producer forever once the 128-slot queue fills — that
            # would pin the upstream TTS connection open indefinitely.
            async for chunk in gen:
                if not chunk:
                    continue
                try:
                    await asyncio.wait_for(queue.put(chunk), timeout=_STREAM_IDLE_TIMEOUT)
                except TimeoutError:
                    logger.warning("tts stream abandoned by consumer; closing")
                    return
        except asyncio.CancelledError:
            raise
        except Exception as e:
            logger.warning("tts stream error mid-flight: %s", e)
        finally:
            # Deterministically close the upstream generator (e.g. ElevenLabs
            # connection) on abandon/cancel instead of leaving it to GC.
            aclose = getattr(gen, "aclose", None)
            if aclose is not None:
                with suppress(Exception):
                    await aclose()
            # Sentinel: tells any consumer no more chunks are coming. Best-effort
            # (the queue may be full precisely because no one is draining it).
            with suppress(asyncio.QueueFull):
                queue.put_nowait(None)

    t = asyncio.create_task(producer())
    _bg_tasks.add(t)
    t.add_done_callback(_bg_tasks.discard)
    store.set_producer(audio_id, t)
    return f"/api/audio/{audio_id}"


async def _read_capped(file: UploadFile, cap: int) -> bytes:
    chunks: list[bytes] = []
    total = 0
    while True:
        chunk = await file.read(64 * 1024)
        if not chunk:
            break
        total += len(chunk)
        if total > cap:
            raise HTTPException(status_code=413, detail=f"audio exceeds {cap} bytes")
        chunks.append(chunk)
    return b"".join(chunks)


def _resolve_harness(app: FastAPI, name: str | None) -> HarnessClient:
    """Look up the harness backing this turn; 422 on an unknown name."""
    harnesses: dict[str, HarnessClient] = app.state.harnesses
    key = name or app.state.default_harness
    client = harnesses.get(key)
    if client is None:
        raise HTTPException(
            status_code=422,
            detail=f"unknown harness '{key}'; available: {', '.join(sorted(harnesses))}",
        )
    return client


async def _run_turn(
    app: FastAPI,
    *,
    harness: HarnessClient | None = None,
    user_text: str,
    session_id: str | None,
    voice_id: str | None = None,
    tts_mode: str | None = None,
) -> TurnResponse:
    import time

    hermes: HarnessClient = harness or app.state.harnesses[app.state.default_harness]
    tts: TTSProvider | None = app.state.tts
    store: AudioStore = app.state.store
    settings: Settings = app.state.settings

    turn_started_at = time.time() - 0.5  # small skew so we don't miss the first tool call

    try:
        reply = await hermes.ask(user_text, session_id=session_id)
    except HermesError as e:
        logger.warning("hermes error: %s", e)
        raise HTTPException(status_code=502, detail=f"hermes failed: {e}") from e

    final_session = reply.session_id or (session_id or "")

    # Spawn TTS immediately so the audio stream starts while we audit. Audit
    # is a separate subprocess call (~150-250ms) that has no dependency on
    # TTS; running them concurrently shaves the audit time off perceived
    # latency. The TTS producer is already a background task; we just need
    # to not block on the audit before kicking it off.
    audio_url: str | None = None
    if tts is not None and tts_mode != "none":
        try:
            # IMPORTANT: only the assistant prose is synthesized. Tool calls
            # are never spoken — they're for visual auditing only. The spoken
            # copy is de-markdowned (make_speakable) so TTS never reads "##",
            # asterisks, or code fences aloud; the displayed text stays raw.
            audio_url = _start_stream(app, tts, make_speakable(reply.text), voice_id=voice_id)
        except Exception as e:
            logger.warning("tts setup error (returning text-only): %s", e)

    # Audit tool calls from this turn (best-effort; never fails the turn).
    # This now races with TTS first-chunk synthesis — usually audit wins
    # by ~50ms, but either way we don't make iOS wait longer.
    tool_summaries: list[ToolCallSummary] = []
    if final_session and not app.state.auto_mock:
        try:
            raw = await fetch_tool_calls_since(settings, final_session, turn_started_at)
            tool_summaries = [ToolCallSummary(**tc.as_dict()) for tc in raw]
        except Exception as e:
            logger.warning("tool-call audit failed: %s", e)

    return TurnResponse(
        session_id=final_session,
        user_text=user_text,
        assistant_text=reply.text,
        audio_url=audio_url,
        tool_calls=tool_summaries,
    )


async def _stream_turn(
    app: FastAPI,
    *,
    harness: HarnessClient | None = None,
    user_text: str,
    session_id: str | None,
    voice_id: str | None = None,
    tts_mode: str | None = None,
    mode: str | None = None,
):
    """SSE event generator for a streaming turn.

    Emits: transcribed → tool* (live, as Hermes flushes them) → tools
    (authoritative) → assistant → audio → done, or an error event. The reply +
    final tool list come from the session export; the live tool events are
    display-only. Additive: the non-streaming /api/text and /api/audio remain
    as the client's fallback.
    """
    hermes: HarnessClient = harness or app.state.harnesses[app.state.default_harness]
    tts: TTSProvider | None = app.state.tts

    def sse(obj: dict) -> str:
        return f"data: {json.dumps(obj)}\n\n"

    # Phase B: a WRITE turn on Claude goes through the SDK approval path — writes
    # and commands pause for a voice yes/no, and the agent can ask the user
    # questions. Reads still auto-approve. Other harnesses / read turns fall
    # through to the standard streaming path below.
    if mode == "write" and getattr(hermes, "bin", None) == "claude":
        from .claude_sdk_turn import stream_claude_approval_turn

        async for event in stream_claude_approval_turn(
            app, user_text=user_text, session_id=session_id,
            voice_id=voice_id, tts_mode=tts_mode,
        ):
            yield sse(event)
        return

    yield sse({"type": "transcribed", "text": user_text})
    try:
        async for ev in hermes.ask_streaming(user_text, session_id=session_id):
            if isinstance(ev, StreamTool):
                yield sse({"type": "tool", "name": ev.name, "preview": ev.preview, "ok": True})
            elif isinstance(ev, StreamReply):
                yield sse({"type": "tools", "items": [tc.as_dict() for tc in ev.tools]})
                yield sse({"type": "assistant", "text": ev.text, "session_id": ev.session_id})
                audio_url: str | None = None
                if tts is not None and ev.text and tts_mode != "none":
                    try:
                        # Speak the de-markdowned copy; the emitted assistant
                        # text above stays raw for the transcript.
                        audio_url = _start_stream(app, tts, make_speakable(ev.text), voice_id=voice_id)
                    except Exception as e:
                        logger.warning("stream tts setup error: %s", e)
                if audio_url:
                    yield sse({"type": "audio", "url": audio_url})
                yield sse({"type": "done", "session_id": ev.session_id})
    except HermesError as e:
        logger.warning("stream hermes error: %s", e)
        yield sse({"type": "error", "detail": f"hermes failed: {e}"})
    except Exception as e:
        logger.warning("stream turn error: %s", e)
        yield sse({"type": "error", "detail": str(e)})


# Convenience for `uvicorn app.main:app`.
app = create_app()
