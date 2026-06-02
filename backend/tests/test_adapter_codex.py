"""Pure-parser tests for the Codex adapter — no subprocess.

The event fixtures below are REAL JSONL events captured from codex-cli 0.136.0
(`codex exec ... --json`). We feed already-decoded dicts to the module-level
CodexAccumulator and assert the live StreamTool(s) + the final StreamReply.
"""
from __future__ import annotations

from app.adapters.codex import (
    CodexAccumulator,
    _build_args,
    parse_session_id,
)
from app.hermes import StreamReply, StreamTool
from app.session_audit import ToolCallSummary


# Real capture: a turn that ran `echo hi`, then replied "done".
TOOL_TURN_EVENTS = [
    {"type": "thread.started", "thread_id": "019e88a7-2b5a-7852-a3b9-517b5e25b0a4"},
    {"type": "turn.started"},
    {"type": "item.started", "item": {
        "id": "item_0", "type": "command_execution",
        "command": "/bin/zsh -lc 'echo hi'",
        "aggregated_output": "", "exit_code": None, "status": "in_progress"}},
    {"type": "item.completed", "item": {
        "id": "item_0", "type": "command_execution",
        "command": "/bin/zsh -lc 'echo hi'",
        "aggregated_output": "hi\n", "exit_code": 0, "status": "completed"}},
    {"type": "item.completed", "item": {
        "id": "item_1", "type": "agent_message", "text": "done"}},
    {"type": "turn.completed", "usage": {"input_tokens": 43451, "output_tokens": 66}},
]

# Real capture: simplest possible turn (no tools), replies "hello".
PLAIN_TURN_EVENTS = [
    {"type": "thread.started", "thread_id": "019e88a6-0b74-7df0-a9bd-19bc108a359e"},
    {"type": "turn.started"},
    {"type": "item.completed", "item": {
        "id": "item_0", "type": "agent_message", "text": "hello"}},
    {"type": "turn.completed", "usage": {"input_tokens": 21582, "output_tokens": 17}},
]


def _run(events):
    """Feed events through the accumulator; return (live_tools, final_reply)."""
    acc = CodexAccumulator()
    live: list[StreamTool] = []
    for ev in events:
        out = acc.feed(ev)
        if out is not None:
            live.append(out)
    return live, acc.build_reply()


def test_parse_session_id():
    assert parse_session_id(TOOL_TURN_EVENTS[0]) == "019e88a7-2b5a-7852-a3b9-517b5e25b0a4"
    assert parse_session_id({"type": "turn.started"}) is None
    assert parse_session_id({"type": "thread.started"}) is None  # no thread_id


def test_plain_turn_yields_only_final_reply():
    live, reply = _run(PLAIN_TURN_EVENTS)
    assert live == []  # no tool calls → no live StreamTool events
    assert isinstance(reply, StreamReply)
    assert reply.text == "hello"
    assert reply.session_id == "019e88a6-0b74-7df0-a9bd-19bc108a359e"
    assert reply.tools == []


def test_tool_turn_emits_live_tool_then_reply():
    live, reply = _run(TOOL_TURN_EVENTS)

    # The command_execution item.started yields exactly one live StreamTool.
    assert len(live) == 1
    assert isinstance(live[0], StreamTool)
    assert live[0].name == "terminal"
    assert "echo hi" in live[0].preview

    # Final reply: text + session id + one tool summary with ok from exit_code.
    assert reply.text == "done"
    assert reply.session_id == "019e88a7-2b5a-7852-a3b9-517b5e25b0a4"
    assert len(reply.tools) == 1
    summary = reply.tools[0]
    assert isinstance(summary, ToolCallSummary)
    assert summary.name == "terminal"
    assert "echo hi" in summary.preview
    assert summary.ok is True


def test_failed_command_marks_tool_not_ok():
    events = [
        {"type": "thread.started", "thread_id": "tid-fail"},
        {"type": "item.started", "item": {
            "id": "c1", "type": "command_execution",
            "command": "/bin/zsh -lc 'false'", "exit_code": None,
            "status": "in_progress"}},
        {"type": "item.completed", "item": {
            "id": "c1", "type": "command_execution",
            "command": "/bin/zsh -lc 'false'", "exit_code": 1,
            "status": "completed"}},
        {"type": "item.completed", "item": {
            "id": "m1", "type": "agent_message", "text": "that failed"}},
        {"type": "turn.completed"},
    ]
    live, reply = _run(events)
    assert len(live) == 1
    assert reply.tools[0].ok is False
    assert reply.text == "that failed"
    assert reply.session_id == "tid-fail"


def test_file_change_item_is_summarized():
    # Real capture: a file_change item adding hello.txt.
    events = [
        {"type": "thread.started", "thread_id": "tid-file"},
        {"type": "item.started", "item": {
            "id": "f1", "type": "file_change",
            "changes": [{"path": "/tmp/ws/hello.txt", "kind": "add"}],
            "status": "in_progress"}},
        {"type": "item.completed", "item": {
            "id": "f1", "type": "file_change",
            "changes": [{"path": "/tmp/ws/hello.txt", "kind": "add"}],
            "status": "completed"}},
        {"type": "item.completed", "item": {
            "id": "m1", "type": "agent_message", "text": "wrote it"}},
        {"type": "turn.completed"},
    ]
    live, reply = _run(events)
    assert len(live) == 1
    assert live[0].name == "edit"
    assert "hello.txt" in live[0].preview
    assert len(reply.tools) == 1
    assert reply.tools[0].ok is True
    assert reply.text == "wrote it"


def test_last_agent_message_wins():
    # Intermediate agent_message (reasoning) followed by the real answer.
    events = [
        {"type": "thread.started", "thread_id": "tid-multi"},
        {"type": "item.completed", "item": {
            "id": "m0", "type": "agent_message",
            "text": "Using a skill because the rules require it."}},
        {"type": "item.completed", "item": {
            "id": "m1", "type": "agent_message", "text": "final answer"}},
        {"type": "turn.completed"},
    ]
    _, reply = _run(events)
    assert reply.text == "final answer"


def test_build_args_oneshot_vs_resume():
    one = _build_args("hi", None, "workspace-write")
    assert one[:3] == ["codex", "exec", "hi"]
    assert "--json" in one
    assert "--skip-git-repo-check" in one
    assert "approval_policy=\"never\"" in one
    assert "sandbox_mode=\"workspace-write\"" in one
    # No resume subcommand on a one-shot.
    assert "resume" not in one

    res = _build_args("hi again", "sess-123", "workspace-write")
    assert res[:5] == ["codex", "exec", "resume", "sess-123", "hi again"]
    assert "--json" in res
    assert "approval_policy=\"never\"" in res
