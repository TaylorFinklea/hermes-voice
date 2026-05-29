"""FastAPI app exposing /health, /api/text, /api/audio, /api/audio/{id}."""
from __future__ import annotations

import asyncio
import logging
import secrets
from contextlib import asynccontextmanager
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
from .audio_store import AudioStore
from .config import Settings, get_settings
from .hermes import HermesClient, HermesError, MockHermesClient
from .models import (
    DeviceRegisterRequest,
    DeviceResponse,
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
    TurnResponse,
)
from .session_audit import fetch_tool_calls_since
from .sessions import get_session, list_sessions
from .stt import STTProvider, make_stt
from .tts import TTSProvider, make_tts

logger = logging.getLogger("hermes_voice")
logger.setLevel(logging.INFO)

# 25 MB cap on /api/audio uploads — well over any realistic short utterance.
MAX_AUDIO_BYTES = 25 * 1024 * 1024


def create_app(
    *,
    hermes: HermesClient | None = None,
    stt: STTProvider | None = None,
    tts: TTSProvider | None = None,
    store: AudioStore | None = None,
) -> FastAPI:
    settings = get_settings()
    auto_mock = settings.mock or _should_auto_mock(settings)

    if hermes is None:
        hermes = MockHermesClient(settings) if auto_mock else HermesClient(settings)
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
            await mdns.stop_mdns(mdns_state)
            task.cancel()
            try:
                await task
            except (asyncio.CancelledError, Exception):
                pass

    app = FastAPI(
        title="Hermes Voice Backend",
        version="0.1.0",
        lifespan=lifespan,
    )
    app.state.settings = settings
    app.state.hermes = hermes
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


def _require_token(
    request: Request,
    x_hermes_voice_token: Annotated[str | None, Header()] = None,
) -> None:
    expected = request.app.state.settings.auth_token
    if not expected:
        return
    if not x_hermes_voice_token or not secrets.compare_digest(
        x_hermes_voice_token, expected
    ):
        raise HTTPException(status_code=401, detail="invalid or missing token")


def _register_routes(app: FastAPI) -> None:
    @app.get("/health", response_model=HealthResponse)
    async def health(request: Request) -> HealthResponse:
        hermes: HermesClient = app.state.hermes
        stt: STTProvider | None = app.state.stt
        tts: TTSProvider | None = app.state.tts
        return HealthResponse(
            status="ok",
            mock=app.state.auto_mock,
            hermes=hermes.describe(),
            stt=(stt.describe() if stt else {"name": "none", "configured": False}),
            tts=(tts.describe() if tts else {"name": "none", "configured": False}),
            scheme=request.url.scheme,
        )

    @app.post(
        "/api/text",
        response_model=TurnResponse,
        dependencies=[Depends(_require_token)],
    )
    async def text_turn(body: TextRequest) -> TurnResponse:
        return await _run_turn(app, user_text=body.text, session_id=body.session_id)

    @app.post(
        "/api/audio",
        response_model=TurnResponse,
        dependencies=[Depends(_require_token)],
    )
    async def audio_turn(
        file: Annotated[UploadFile, File()],
        session_id: Annotated[str | None, Form()] = None,
    ) -> TurnResponse:
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

        return await _run_turn(app, user_text=user_text, session_id=session_id)

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
            audio_url = _start_stream(app, tts, body.text)
        except Exception as e:
            logger.warning("replay tts error: %s", e)
            raise HTTPException(status_code=502, detail=f"tts failed: {e}") from e
        return ReplayResponse(audio_url=audio_url)

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


def _start_stream(app: FastAPI, tts: TTSProvider, text: str) -> str:
    """Kick off a background streaming-TTS task and return the audio URL.

    The HTTP response can come back to iOS before any audio is synthesized;
    iOS hits the audio URL and reads chunks as ElevenLabs produces them.
    """
    store: AudioStore = app.state.store
    audio_id, queue = store.start_stream(tts.stream_extension, tts.stream_mime)

    async def producer() -> None:
        try:
            async for chunk in tts.stream(text):
                if chunk:
                    await queue.put(chunk)
        except Exception as e:
            logger.warning("tts stream error mid-flight: %s", e)
        finally:
            # Sentinel: tells consumers no more chunks are coming.
            await queue.put(None)

    asyncio.create_task(producer())
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


async def _run_turn(app: FastAPI, *, user_text: str, session_id: str | None) -> TurnResponse:
    import time

    hermes: HermesClient = app.state.hermes
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
    if tts is not None:
        try:
            # IMPORTANT: only the assistant prose is synthesized. Tool calls
            # are never spoken — they're for visual auditing only.
            audio_url = _start_stream(app, tts, reply.text)
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


# Convenience for `uvicorn app.main:app`.
app = create_app()
