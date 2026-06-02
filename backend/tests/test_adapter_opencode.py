"""Pure-parser tests for the OpenCode adapter.

These feed canned JSON events (captured from a real `opencode run --format
json` v1.15.13 invocation) to the module-level pure functions — no subprocess.
We assert the live StreamTool(s) emitted and the final accumulated reply
(text, session_id, tools).
"""
from __future__ import annotations

from app.adapters.opencode import (
    Accumulator,
    fold_event,
    parse_event,
)
from app.hermes import StreamReply, StreamTool

SES = "ses_177588e5ffferF0c0aDVrhsKhe"

# Captured from a real run: "Create a file called note.txt ... then read it
# back." The model narrates (commentary text), applies a patch, reads the
# file, then gives a final answer.
TOOL_RUN_EVENTS = [
    {
        "type": "step_start",
        "sessionID": SES,
        "part": {"type": "step-start", "id": "prt_a", "sessionID": SES},
    },
    {
        "type": "text",
        "sessionID": SES,
        "part": {
            "type": "text",
            "text": "Creating `note.txt`, then I’ll read it back.",
            "metadata": {"openai": {"phase": "commentary"}},
        },
    },
    {
        "type": "tool_use",
        "sessionID": SES,
        "part": {
            "type": "tool",
            "tool": "apply_patch",
            "callID": "call_OwBnjCeHIAyM8hQjbhCWKbtG",
            "state": {
                "status": "completed",
                "input": {
                    "patchText": "*** Begin Patch\n*** Add File: note.txt\n+hi there\n*** End Patch"
                },
                "output": "Success.",
            },
        },
    },
    {
        "type": "tool_use",
        "sessionID": SES,
        "part": {
            "type": "tool",
            "tool": "read",
            "callID": "call_6n0NAhwHse6fMWePBOnv7JDR",
            "state": {
                "status": "completed",
                "input": {"filePath": "/tmp/note.txt", "offset": 1, "limit": 20},
                "output": "hi there",
            },
        },
    },
    {
        "type": "text",
        "sessionID": SES,
        "part": {
            "type": "text",
            "text": "Created and read back note.txt: hi there",
            "metadata": {"openai": {"phase": "final_answer"}},
        },
    },
    {
        "type": "step_finish",
        "sessionID": SES,
        "part": {"type": "step-finish", "reason": "stop", "sessionID": SES},
    },
]

# Captured from the "Reply with only the word: hello" run (no tools).
HELLO_RUN_EVENTS = [
    {
        "type": "step_start",
        "sessionID": "ses_177590a98ffeWMAr9oDvZzLR5k",
        "part": {"type": "step-start"},
    },
    {
        "type": "text",
        "sessionID": "ses_177590a98ffeWMAr9oDvZzLR5k",
        "part": {
            "type": "text",
            "text": "hello",
            "metadata": {"openai": {"phase": "final_answer"}},
        },
    },
    {
        "type": "step_finish",
        "sessionID": "ses_177590a98ffeWMAr9oDvZzLR5k",
        "part": {"type": "step-finish", "reason": "stop"},
    },
]


def _drive(events):
    """Fold a list of events the way ask_streaming does, collecting StreamTools."""
    acc = Accumulator()
    live_tools = []
    for ev in events:
        tool = fold_event(acc, ev)
        if tool is not None:
            live_tools.append(tool)
    return acc, live_tools


def test_hello_run_yields_text_and_session_no_tools():
    acc, live_tools = _drive(HELLO_RUN_EVENTS)
    assert acc.text == "hello"
    assert acc.session_id == "ses_177590a98ffeWMAr9oDvZzLR5k"
    assert acc.tools == []
    assert live_tools == []


def test_tool_run_streams_each_tool_live():
    _acc, live_tools = _drive(TOOL_RUN_EVENTS)
    # Two terminal tool events → two live StreamTool previews, in order.
    assert len(live_tools) == 2
    assert all(isinstance(t, StreamTool) for t in live_tools)
    assert [t.name for t in live_tools] == ["apply_patch", "read"]
    # Previews are synthesized by session_audit._preview from the tool args.
    assert live_tools[0].preview  # non-empty
    assert "note.txt" in live_tools[1].preview


def test_tool_run_final_reply_prefers_final_answer_over_commentary():
    acc, _ = _drive(TOOL_RUN_EVENTS)
    # The commentary text must NOT win over the final_answer text.
    assert acc.text == "Created and read back note.txt: hi there"
    assert acc.session_id == SES


def test_tool_run_accumulates_tool_summaries():
    acc, _ = _drive(TOOL_RUN_EVENTS)
    assert [t.name for t in acc.tools] == ["apply_patch", "read"]
    assert all(t.ok for t in acc.tools)  # both completed without error


def test_final_stream_reply_shape():
    acc, _ = _drive(TOOL_RUN_EVENTS)
    reply = StreamReply(
        text=acc.text, session_id=acc.session_id, tools=list(acc.tools)
    )
    assert reply.text == "Created and read back note.txt: hi there"
    assert reply.session_id == SES
    assert len(reply.tools) == 2


def test_errored_tool_marked_not_ok():
    events = [
        {
            "type": "tool_use",
            "sessionID": SES,
            "part": {
                "type": "tool",
                "tool": "bash",
                "callID": "call_x",
                "state": {
                    "status": "error",
                    "input": {"command": "false"},
                    "error": "exit 1",
                },
            },
        },
        {
            "type": "text",
            "sessionID": SES,
            "part": {
                "type": "text",
                "text": "That failed.",
                "metadata": {"openai": {"phase": "final_answer"}},
            },
        },
    ]
    acc, live_tools = _drive(events)
    assert len(acc.tools) == 1
    assert acc.tools[0].name == "bash"
    assert acc.tools[0].ok is False
    assert len(live_tools) == 1


def test_pending_tool_not_emitted_until_terminal():
    # A tool part still running must not produce a StreamTool or summary.
    pending = {
        "type": "tool_use",
        "sessionID": SES,
        "part": {
            "type": "tool",
            "tool": "read",
            "callID": "call_y",
            "state": {"status": "running", "input": {"filePath": "/tmp/x"}},
        },
    }
    assert parse_event(pending) is None
    acc, live_tools = _drive([pending])
    assert acc.tools == []
    assert live_tools == []


def test_parse_event_returns_streamtool_for_completed_tool():
    completed = TOOL_RUN_EVENTS[2]  # the apply_patch tool_use event
    tool = parse_event(completed)
    assert isinstance(tool, StreamTool)
    assert tool.name == "apply_patch"


def test_parse_event_ignores_text_and_step_events():
    assert parse_event(HELLO_RUN_EVENTS[0]) is None  # step_start
    assert parse_event(HELLO_RUN_EVENTS[1]) is None  # text
    assert parse_event(HELLO_RUN_EVENTS[2]) is None  # step_finish


def test_session_id_captured_from_part_when_top_level_absent():
    ev = {
        "type": "text",
        "part": {
            "type": "text",
            "text": "hi",
            "sessionID": "ses_frompart",
            "metadata": {"openai": {"phase": "final_answer"}},
        },
    }
    acc, _ = _drive([ev])
    assert acc.session_id == "ses_frompart"
    assert acc.text == "hi"
