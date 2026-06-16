"""Tests for the ACP warm-server client (Hermes rock-solid migration, Phase 1).

The unavoidable external dependency — the `hermes acp` subprocess speaking
JSON-RPC — is replaced by a `FakeConn` that fires the SYNC stream observer inline
during prompt(), exactly as the real acp Connection's receive loop does (in wire
order, before the prompt response resolves). The logic under test (observer
routing, _drive_turn event→StreamTool/StreamReply mapping, session reuse,
timeout/lifecycle, auto-approve) is the real code.
"""
from __future__ import annotations

import asyncio
from types import SimpleNamespace

import pytest

from app import acp_client
from app.config import get_settings
from app.hermes import HermesError, StreamReply, StreamTool
from app.session_audit import ToolCallSummary

# --- ACP wire-shaped fake events (raw dicts, camelCase aliases) --------------

def _msg(text: str) -> dict:
    return {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}


def _tool(title: str, tool_call_id: str, status: str = "in_progress") -> dict:
    return {
        "sessionUpdate": "tool_call",
        "title": title,
        "toolCallId": tool_call_id,
        "status": status,
    }


def _tool_update(tool_call_id: str, status: str) -> dict:
    return {"sessionUpdate": "tool_call_update", "toolCallId": tool_call_id, "status": status}


def _su_event(session_id: str, update: dict) -> SimpleNamespace:
    """A StreamEvent-shaped object the observer accepts (direction + raw message)."""
    return SimpleNamespace(
        direction="incoming",
        message={"method": "session/update", "params": {"sessionId": session_id, "update": update}},
    )


class FakeConn:
    """Stands in for an ACP ClientSideConnection. Fires `observer` inline during
    prompt() (mirroring the real receive loop), then resolves the response."""

    def __init__(self, observer, events, *, new_session_id="sess-new", raise_in_prompt=None):
        self._observer = observer
        self._events = events
        self._new_session_id = new_session_id
        self._raise = raise_in_prompt
        self.new_session_calls = 0
        self.cancels: list[str] = []

    async def new_session(self, cwd):
        self.new_session_calls += 1
        return SimpleNamespace(session_id=self._new_session_id)

    async def prompt(self, prompt, session_id):
        for ev in self._events:
            self._observer(_su_event(session_id, ev))  # inline, before the response
        if self._raise is not None:
            raise self._raise
        return SimpleNamespace(stop_reason="end_turn")

    async def cancel(self, session_id):
        self.cancels.append(session_id)


async def _collect(agen):
    return [ev async for ev in agen]


async def _drive(conn, obs, session_id, text="hi"):
    return await _collect(
        acp_client._drive_turn(conn, obs, session_id=session_id, text=text, cwd="/tmp")
    )


# --- _AcpStreamObserver ------------------------------------------------------

async def test_observer_routes_update_only_to_registered_session_queue():
    obs = acp_client._AcpStreamObserver()
    q = obs.register("s1")
    obs(_su_event("s1", _msg("hi")))
    obs(_su_event("other", _msg("ignored")))
    assert q.qsize() == 1
    assert q.get_nowait()["content"]["text"] == "hi"


async def test_observer_ignores_outgoing_and_non_session_update():
    obs = acp_client._AcpStreamObserver()
    q = obs.register("s1")
    outgoing = SimpleNamespace(
        direction="outgoing",
        message={"method": "session/update", "params": {"sessionId": "s1", "update": _msg("x")}},
    )
    other = SimpleNamespace(
        direction="incoming",
        message={"method": "session/request_permission", "params": {}},
    )
    obs(outgoing)
    obs(other)
    assert q.qsize() == 0


def test_observer_unregister_keeps_a_newer_queue_for_the_same_session():
    obs = acp_client._AcpStreamObserver()
    q1 = obs.register("s1")
    q2 = obs.register("s1")
    obs.unregister("s1", q1)  # stale cleanup
    assert obs._queues.get("s1") is q2


# --- _drive_turn -------------------------------------------------------------

async def test_drive_turn_accumulates_message_chunks_into_one_reply():
    obs = acp_client._AcpStreamObserver()
    conn = FakeConn(obs, [_msg("Saved"), _msg(" and reminder set.")])
    out = await _drive(conn, obs, "s1")
    replies = [e for e in out if isinstance(e, StreamReply)]
    assert len(replies) == 1
    assert replies[0].text == "Saved and reminder set."
    assert replies[0].session_id == "s1"


async def test_drive_turn_emits_stream_tool_then_reply_with_summary():
    obs = acp_client._AcpStreamObserver()
    events = [
        _tool("terminal: $ echo hi", "tc-1"),
        _tool_update("tc-1", status="completed"),
        _msg("Done."),
    ]
    conn = FakeConn(obs, events)
    out = await _drive(conn, obs, "s1", text="run it")
    tools = [e for e in out if isinstance(e, StreamTool)]
    reply = next(e for e in out if isinstance(e, StreamReply))
    assert [(t.name, t.preview) for t in tools] == [("terminal", "$ echo hi")]
    assert reply.text == "Done."
    assert reply.tools == [ToolCallSummary(name="terminal", preview="$ echo hi", ok=True)]


async def test_drive_turn_marks_failed_tool_not_ok():
    obs = acp_client._AcpStreamObserver()
    events = [
        _tool("read_file: /nope", "tc-9"),
        _tool_update("tc-9", status="failed"),
        _msg("Couldn't."),
    ]
    conn = FakeConn(obs, events)
    out = await _drive(conn, obs, "s1", text="read")
    reply = next(e for e in out if isinstance(e, StreamReply))
    assert reply.tools == [ToolCallSummary(name="read_file", preview="/nope", ok=False)]


async def test_drive_turn_reuses_given_session_without_new_session():
    obs = acp_client._AcpStreamObserver()
    conn = FakeConn(obs, [_msg("ok")])
    out = await _drive(conn, obs, "existing")
    assert conn.new_session_calls == 0
    assert next(e for e in out if isinstance(e, StreamReply)).session_id == "existing"


async def test_drive_turn_creates_session_when_none_given():
    obs = acp_client._AcpStreamObserver()
    conn = FakeConn(obs, [_msg("ok")], new_session_id="fresh-uuid")
    out = await _drive(conn, obs, None)
    assert conn.new_session_calls == 1
    assert next(e for e in out if isinstance(e, StreamReply)).session_id == "fresh-uuid"


async def test_drive_turn_raises_on_empty_reply():
    obs = acp_client._AcpStreamObserver()
    conn = FakeConn(obs, [])
    with pytest.raises(HermesError):
        await _drive(conn, obs, "s1")


async def test_drive_turn_unregisters_session_queue_after_turn():
    obs = acp_client._AcpStreamObserver()
    conn = FakeConn(obs, [_msg("ok")])
    await _drive(conn, obs, "s1")
    assert "s1" not in obs._queues


async def test_drive_turn_propagates_prompt_error():
    obs = acp_client._AcpStreamObserver()
    conn = FakeConn(obs, [_msg("partial")], raise_in_prompt=RuntimeError("boom"))
    with pytest.raises(RuntimeError):
        await _drive(conn, obs, "s1")


async def test_drive_turn_cancels_child_when_abandoned_mid_turn():
    # A turn abandoned before the prompt resolves (barge-in / client disconnect)
    # must send session/cancel so the warm child stops generating instead of
    # running on in the background and tying up the next turn.
    obs = acp_client._AcpStreamObserver()

    class HangingConn:
        def __init__(self) -> None:
            self.cancels: list[str] = []

        async def prompt(self, prompt, session_id):
            obs(_su_event(session_id, _tool("read_file: /x", "tc-1")))
            await asyncio.Event().wait()  # never resolves: turn stays mid-flight

        async def cancel(self, session_id):
            self.cancels.append(session_id)

    conn = HangingConn()
    agen = acp_client._drive_turn(conn, obs, session_id="s1", text="hi", cwd="/tmp")
    first = await agen.__anext__()  # the live StreamTool, mid-turn
    assert isinstance(first, StreamTool)
    await agen.aclose()             # abandon the turn before completion

    assert conn.cancels == ["s1"]   # child told to stop generating
    assert "s1" not in obs._queues  # observer queue still cleaned up


# --- _AcpClient (permission callback) ----------------------------------------

async def test_acp_client_auto_approves_an_allow_option():
    client = acp_client._AcpClient()
    options = [
        SimpleNamespace(kind="reject_once", name="Deny", option_id="opt-deny"),
        SimpleNamespace(kind="allow_once", name="Allow", option_id="opt-allow"),
    ]
    resp = await client.request_permission(
        options=options, session_id="s1", tool_call=SimpleNamespace()
    )
    assert resp.outcome.option_id == "opt-allow"


async def test_acp_client_request_permission_with_no_options_raises():
    client = acp_client._AcpClient()
    with pytest.raises(HermesError):
        await client.request_permission(options=[], session_id="s1", tool_call=SimpleNamespace())


# --- HermesAcpClient.ask / ask_streaming -------------------------------------

async def test_ask_returns_hermes_reply_from_injected_conn():
    client = acp_client.HermesAcpClient(get_settings())
    obs = acp_client._AcpStreamObserver()
    client._observer = obs
    client._conn = FakeConn(obs, [_msg("Saved.")])
    client._started = True
    client._proc = SimpleNamespace(returncode=None)

    reply = await client.ask("save this", session_id="s1")
    assert reply.text == "Saved."
    assert reply.session_id == "s1"


async def test_ask_fully_drains_generator_so_no_queue_leaks():
    client = acp_client.HermesAcpClient(get_settings())
    obs = acp_client._AcpStreamObserver()
    client._observer = obs
    client._conn = FakeConn(obs, [_msg("ok")])
    client._started = True
    client._proc = SimpleNamespace(returncode=None)

    await client.ask("hi", session_id="s1")
    assert obs._queues == {}


async def test_ask_streaming_wraps_prompt_error_as_hermes_error():
    client = acp_client.HermesAcpClient(get_settings())
    obs = acp_client._AcpStreamObserver()
    client._observer = obs
    client._conn = FakeConn(obs, [_msg("x")], raise_in_prompt=RuntimeError("boom"))
    client._started = True
    client._proc = SimpleNamespace(returncode=None)

    with pytest.raises(HermesError):
        async for _ in client.ask_streaming("hi", session_id="s1"):
            pass


def _fake_acp_spawn(state):
    """A fake `acp.spawn_agent_process`: each spawn returns a fresh conn+proc
    whose conn fires the registered observer inline during prompt()."""

    def spawn(to_client, *args, observers=None, **kwargs):
        obs = observers[0] if observers else None

        class FakeProc:
            returncode = None

        proc = FakeProc()
        state.setdefault("procs", []).append(proc)

        class FakeReConn:
            async def initialize(self, protocol_version):
                return SimpleNamespace()

            async def new_session(self, cwd):
                return SimpleNamespace(session_id="sess")

            async def prompt(self, prompt, session_id):
                obs(_su_event(session_id, _msg("ok")))
                return SimpleNamespace(stop_reason="end_turn")

            async def cancel(self, session_id):
                pass

        conn = FakeReConn()

        class FakeCM:
            async def __aenter__(self):
                state["spawns"] = state.get("spawns", 0) + 1
                return conn, proc

            async def __aexit__(self, *a):
                state["exits"] = state.get("exits", 0) + 1

        return FakeCM()

    return spawn


async def test_turn_respawns_a_dead_warm_child(monkeypatch):
    state = {}
    monkeypatch.setattr(acp_client.acp, "spawn_agent_process", _fake_acp_spawn(state))

    client = acp_client.HermesAcpClient(get_settings())
    await client.start()
    assert state["spawns"] == 1

    assert (await client.ask("hi")).text == "ok"

    state["procs"][-1].returncode = 1  # the warm child dies

    assert (await client.ask("hi again")).text == "ok"  # next turn self-heals
    assert state["spawns"] == 2  # respawned a fresh child

    await client.aclose()


# --- lifecycle: start / aclose / describe ------------------------------------

async def test_start_is_idempotent_and_aclose_resets_state(monkeypatch):
    entered = {"n": 0}
    exited = {"n": 0}

    class FakeProc:
        returncode = None

    class FakeConnLifecycle:
        async def initialize(self, protocol_version):
            return SimpleNamespace()

    class FakeCM:
        async def __aenter__(self):
            entered["n"] += 1
            return FakeConnLifecycle(), FakeProc()

        async def __aexit__(self, *a):
            exited["n"] += 1

    monkeypatch.setattr(acp_client.acp, "spawn_agent_process", lambda *a, **k: FakeCM())

    client = acp_client.HermesAcpClient(get_settings())
    await client.start()
    assert client._started is True
    assert client.describe()["child_alive"] is True
    await client.start()  # idempotent — no second __aenter__
    assert entered["n"] == 1

    await client.aclose()
    assert client._started is False
    assert exited["n"] == 1
    assert client.describe()["child_alive"] is False


async def test_start_tears_down_child_if_initialize_fails(monkeypatch):
    exited = {"n": 0}

    class FakeProc:
        returncode = None

    class FakeConnLifecycle:
        async def initialize(self, protocol_version):
            raise RuntimeError("init refused")

    class FakeCM:
        async def __aenter__(self):
            return FakeConnLifecycle(), FakeProc()

        async def __aexit__(self, *a):
            exited["n"] += 1

    monkeypatch.setattr(acp_client.acp, "spawn_agent_process", lambda *a, **k: FakeCM())

    client = acp_client.HermesAcpClient(get_settings())
    with pytest.raises(RuntimeError):
        await client.start()
    # partial child torn down, state reset so a retry / describe reflect the truth
    assert exited["n"] == 1
    assert client._started is False
    assert client._conn is None


# --- create_app default-client selection -------------------------------------

def test_make_hermes_selects_acp_only_when_flagged_and_not_mock():
    from app import main
    from app.config import Settings
    from app.hermes import HermesClient, MockHermesClient

    acp_settings = Settings(use_acp=True)
    plain_settings = Settings(use_acp=False)

    assert isinstance(main._make_hermes(acp_settings, auto_mock=False), acp_client.HermesAcpClient)
    assert isinstance(main._make_hermes(plain_settings, auto_mock=False), HermesClient)
    assert isinstance(main._make_hermes(acp_settings, auto_mock=True), MockHermesClient)
