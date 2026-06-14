"""Drive a warm `hermes acp` server over ACP/JSON-RPC instead of cold-starting
`hermes chat` per turn.

Each `hermes chat` subprocess re-pays full agent init (imports, MCP discovery,
credential resolution, model client) before the first token — minutes when an
MCP server stalls. The `hermes acp` server keeps the agent + MCP warm across
turns, so a turn is just model latency (~1-2s). This client speaks ACP to one
long-lived child and satisfies the same `HarnessClient` contract as the legacy
`HermesClient`, so the FastAPI turn pipeline is unchanged.

Spec: .docs/ai/phases/hermes-acp-warm-server-spec.md (Phase 1).

Event collection uses a SYNC `StreamObserver` (acp Connection runs it inline in
the receive loop, in wire order) rather than the async `Client.session_update`
callback. The acp dispatcher runs that callback as a DETACHED task that can lag
the prompt response, so collecting via the callback drops/truncates replies (the
prompt response resolves inline before the detached handlers run). The inline
observer guarantees every `session/update` for a turn is enqueued before
`prompt()` returns — no race.

Security: the ACP server is a co-located child process over stdio (local trust,
no network) — never bind it to a socket without adding auth.
"""
from __future__ import annotations

import asyncio
import contextlib
import shutil
from collections.abc import AsyncIterator
from pathlib import Path

import acp
from acp.schema import AllowedOutcome, RequestPermissionResponse, TextContentBlock

from .config import Settings
from .hermes import _VOICE_PRELUDE, HermesError, HermesReply, StreamReply, StreamTool
from .session_audit import ToolCallSummary


def _text_blocks(text: str) -> list[TextContentBlock]:
    return [TextContentBlock(type="text", text=text)]


def _split_title(title: str) -> tuple[str, str]:
    """ACP tool titles look like "terminal: $ echo hi"; split into (name, preview)
    for StreamTool. NOTE: the ACP title prefix is a human label, not always the
    tool function id (e.g. read_file → "read: …"); display-only, so acceptable —
    a structured tool-name field is a Phase-2 enrichment."""
    if ":" in title:
        name, preview = title.split(":", 1)
        return name.strip(), preview.strip()
    return title.strip(), ""


def _status_ok(status) -> bool:
    # ToolCallStatus is pending|in_progress|completed|failed. Anything not
    # explicitly "failed" is treated as ok (an in-progress tool hasn't failed).
    return status != "failed"


def _pick_allow(options):
    """Choose an allow-ish permission option, else the first offered."""
    for o in options:
        if "allow" in str(getattr(o, "kind", "")).lower():
            return o
    return options[0]


class _AcpStreamObserver:
    """SYNC StreamObserver passed to the acp Connection. Runs inline in the
    receive loop in wire order, routing each `session/update` notification's
    payload (a raw dict) to its session's queue. Inline delivery is what makes
    event collection race-free w.r.t. the prompt response."""

    def __init__(self) -> None:
        self._queues: dict[str, asyncio.Queue] = {}

    def register(self, session_id: str) -> asyncio.Queue:
        q: asyncio.Queue = asyncio.Queue()
        self._queues[session_id] = q
        return q

    def unregister(self, session_id: str, queue: asyncio.Queue | None = None) -> None:
        # Drop only OUR queue, so a stale turn's cleanup can't evict a newer
        # same-session turn's queue (turns are serialized per session, but keep
        # this guard as defense in depth).
        if queue is None or self._queues.get(session_id) is queue:
            self._queues.pop(session_id, None)

    def __call__(self, event) -> None:  # acp StreamObserver (sync → runs inline)
        if event.direction != "incoming":
            return
        msg = event.message
        if msg.get("method") != "session/update":
            return
        params = msg.get("params") or {}
        sid = params.get("sessionId")
        update = params.get("update")
        if sid is None or update is None:
            return
        q = self._queues.get(sid)
        if q is not None:
            q.put_nowait(update)


class _AcpClient:
    """acp.Client callback object. The observer collects `session_update`, so
    that method is a no-op here; we only auto-approve permission requests —
    Phase 1 parity with the no-prompt `hermes chat` path (voice-mediated approval
    is a later phase)."""

    async def session_update(self, session_id, update, **kwargs):
        return None

    async def request_permission(self, options, session_id, tool_call, **kwargs):
        if not options:
            # An approval request with no options is malformed; deny-by-raise so
            # it surfaces rather than IndexError-ing inside the ACP callback.
            raise HermesError("permission request had no options")
        opt = _pick_allow(options)
        return RequestPermissionResponse(
            outcome=AllowedOutcome(outcome="selected", option_id=opt.option_id)
        )

    def on_connect(self, conn):
        pass


def _process_update(update: dict, reply_parts: list[str], tools_by_id: dict, order: list[str]):
    """Fold one ACP `session/update` payload (raw dict, camelCase wire aliases)
    into turn state. Returns a StreamTool to emit live, or None."""
    su = update.get("sessionUpdate")
    if su == "agent_message_chunk":
        text = (update.get("content") or {}).get("text")
        if text:
            reply_parts.append(text)
        return None
    if su == "tool_call":
        name, preview = _split_title(update.get("title") or "")
        tcid = update.get("toolCallId")
        ok = _status_ok(update.get("status"))
        if tcid is not None:
            if tcid not in tools_by_id:
                order.append(tcid)
            tools_by_id[tcid] = ToolCallSummary(name=name, preview=preview, ok=ok)
        return StreamTool(name=name, preview=preview)
    if su == "tool_call_update":
        tcid = update.get("toolCallId")
        if tcid in tools_by_id:
            prev = tools_by_id[tcid]
            status = update.get("status")
            ok = _status_ok(status) if status is not None else prev.ok
            tools_by_id[tcid] = ToolCallSummary(name=prev.name, preview=prev.preview, ok=ok)
        return None
    return None


async def _drive_turn(
    conn, observer: _AcpStreamObserver, *, session_id, text, cwd
) -> AsyncIterator:
    """Run one turn against a warm ACP connection, yielding StreamTool events
    live and a final authoritative StreamReply. Mirrors HermesClient.ask_streaming's
    contract. Because the observer enqueues every notification inline before the
    prompt response resolves, draining the queue once prompt_task completes yields
    the full reply with no dispatch race."""
    sid = session_id
    if not sid:
        resp = await conn.new_session(cwd=cwd)
        sid = resp.session_id
    queue = observer.register(sid)
    reply_parts: list[str] = []
    tools_by_id: dict[str, ToolCallSummary] = {}
    order: list[str] = []

    prompt_task = asyncio.ensure_future(conn.prompt(prompt=_text_blocks(text), session_id=sid))
    try:
        while True:
            getter = asyncio.ensure_future(queue.get())
            done, _ = await asyncio.wait({getter, prompt_task}, return_when=asyncio.FIRST_COMPLETED)
            if getter in done:
                st = _process_update(getter.result(), reply_parts, tools_by_id, order)
                if st is not None:
                    yield st
                continue
            # Prompt resolved → every notification is already enqueued (inline
            # observer, wire order). Cancel the idle getter and drain the rest.
            getter.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await getter
            while not queue.empty():
                st = _process_update(queue.get_nowait(), reply_parts, tools_by_id, order)
                if st is not None:
                    yield st
            break
        await prompt_task  # surface a prompt-side error (RequestError, etc.)
        out = "".join(reply_parts).strip()
        if not out:
            raise HermesError("acp returned no assistant text")
        yield StreamReply(text=out, session_id=sid, tools=[tools_by_id[t] for t in order])
    finally:
        observer.unregister(sid, queue)
        if not prompt_task.done():
            prompt_task.cancel()
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await prompt_task


class HermesAcpClient:
    """Satisfies the HarnessClient contract by driving one warm `hermes acp`
    child. Started/stopped by the FastAPI lifespan (see main.create_app)."""

    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._observer: _AcpStreamObserver | None = None
        self._conn = None
        self._cm = None
        self._proc = None
        self._started = False
        self._lock = asyncio.Lock()
        # Serialize turns per session (voice resumes reuse the session id; the
        # observer routes by session id, so overlapping same-session turns would
        # collide). New conversations (session_id=None) are independent.
        self._session_locks: dict[str, asyncio.Lock] = {}

    def is_available(self) -> bool:
        return shutil.which(self._settings.hermes_bin) is not None

    def describe(self) -> dict:
        alive = self._child_alive()
        return {
            "bin": self._settings.hermes_bin,
            "available": self.is_available(),
            "mode": "acp",
            "started": self._started,
            "child_alive": alive,
            "timeout_seconds": self._settings.hermes_timeout,
        }

    def _child_alive(self) -> bool:
        return self._started and self._proc is not None and self._proc.returncode is None

    async def _spawn(self) -> None:
        """Spawn a fresh `hermes acp` child + initialize it. Caller holds _lock."""
        self._observer = _AcpStreamObserver()
        self._cm = acp.spawn_agent_process(
            lambda agent: _AcpClient(),
            self._settings.hermes_bin,
            "acp",
            use_unstable_protocol=True,
            # Inherit the child's stderr (→ backend log) instead of an undrained
            # PIPE that would deadlock a long-lived child once full.
            transport_kwargs={"stderr": None},
            observers=[self._observer],
        )
        self._conn, self._proc = await self._cm.__aenter__()
        try:
            async with asyncio.timeout(self._settings.hermes_timeout):
                await self._conn.initialize(protocol_version=acp.PROTOCOL_VERSION)
        except BaseException:
            # Tear down the partially-started child so a failed/slow init doesn't
            # leak it for the process lifetime.
            with contextlib.suppress(Exception):
                await self._cm.__aexit__(None, None, None)
            self._cm = self._conn = self._proc = self._observer = None
            raise
        self._started = True

    async def start(self) -> None:
        async with self._lock:
            if self._started:
                return
            await self._spawn()

    async def _ensure_healthy(self) -> None:
        """Respawn the warm child if it died (or was never started). Sessions
        rehydrate from state.db on the next prompt (server-side get_session), so
        a respawn is transparent to an in-progress conversation."""
        async with self._lock:
            if self._child_alive():
                return
            if self._cm is not None:
                with contextlib.suppress(Exception):
                    await self._cm.__aexit__(None, None, None)
            self._cm = self._conn = self._proc = self._observer = None
            self._started = False
            await self._spawn()

    async def aclose(self) -> None:
        async with self._lock:
            if self._cm is None:
                return
            try:
                await self._cm.__aexit__(None, None, None)
            finally:
                self._cm = self._conn = self._proc = self._observer = None
                self._started = False

    def _cwd(self) -> str:
        # Voice turns operate on the user's personal context (notes, calendar,
        # devices), so default to home. A real repo cwd is a coding-attach concern.
        return str(Path.home())

    @contextlib.asynccontextmanager
    async def _turn_guard(self, session_id: str | None):
        # Resumed turns on one session must not overlap; new conversations don't
        # contend (unique fresh session).
        if not session_id:
            yield
            return
        lock = self._session_locks.setdefault(session_id, asyncio.Lock())
        async with lock:
            yield

    async def ask_streaming(self, prompt: str, session_id: str | None = None) -> AsyncIterator:
        if not prompt.strip():
            raise HermesError("empty prompt")
        # Phase 1 parity with the subprocess path: shape only the first turn.
        # Phase 2 moves this onto the session system_prompt so resumes stay shaped.
        shaped = prompt if session_id else f"{_VOICE_PRELUDE}\n\n{prompt}"
        try:
            await self._ensure_healthy()  # respawn a dead/never-started child
            async with self._turn_guard(session_id):
                async with asyncio.timeout(self._settings.hermes_timeout):
                    async for ev in _drive_turn(
                        self._conn,
                        self._observer,
                        session_id=session_id,
                        text=shaped,
                        cwd=self._cwd(),
                    ):
                        yield ev
        except HermesError:
            raise
        except TimeoutError as e:
            raise HermesError(
                f"acp turn timed out after {self._settings.hermes_timeout}s"
            ) from e
        except Exception as e:  # ACP/transport error → loud, typed failure
            raise HermesError(f"acp turn failed: {e}") from e

    async def ask(self, prompt: str, session_id: str | None = None) -> HermesReply:
        # Drain fully — an early return would abandon the generator with its
        # cleanup (unregister) pending, which could evict the next turn's queue.
        reply: StreamReply | None = None
        async for ev in self.ask_streaming(prompt, session_id=session_id):
            if isinstance(ev, StreamReply):
                reply = ev
        if reply is None:
            raise HermesError("acp returned no assistant text")
        return HermesReply(text=reply.text, session_id=reply.session_id)
