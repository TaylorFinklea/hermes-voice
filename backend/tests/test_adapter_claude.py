"""Pure-parser tests for the Claude Code adapter.

Feeds canned (real-captured) stream-json events to the module-level pure
functions and asserts the extracted live StreamTool(s) and the final
StreamReply (text, session_id, tools). No subprocess is spawned.

The fixtures below are abbreviated copies of events captured from a real
`claude -p ... --output-format stream-json --include-partial-messages --verbose`
run against claude v2.1.160 (prompt: read a file and report the next word).
"""
from __future__ import annotations

from app.adapters.claude import (
    StreamAccumulator,
    _parse_compact,
    _parse_oneshot,
    parse_event,
)
from app.hermes import StreamReply, StreamTool

SESSION = "b8d739c0-2376-456f-9047-f4d1e78e1837"
TOOL_USE_ID = "toolu_01AL6bz5UtvA7YYFjooASsFc"

# --- Real-captured stream events (trimmed to the load-bearing fields) ---------

INIT_EVENT = {"type": "system", "subtype": "init", "session_id": SESSION}

ASSISTANT_THINKING_EVENT = {
    "type": "assistant",
    "session_id": SESSION,
    "message": {
        "role": "assistant",
        "content": [{"type": "thinking", "thinking": "", "signature": "abc"}],
    },
}

ASSISTANT_TOOL_USE_EVENT = {
    "type": "assistant",
    "session_id": SESSION,
    "message": {
        "role": "assistant",
        "content": [
            {
                "type": "tool_use",
                "id": TOOL_USE_ID,
                "name": "Read",
                "input": {"file_path": "/tmp/sample.txt"},
                "caller": {"type": "direct"},
            }
        ],
    },
}

USER_TOOL_RESULT_EVENT = {
    "type": "user",
    "session_id": SESSION,
    "message": {
        "role": "user",
        "content": [
            {
                "tool_use_id": TOOL_USE_ID,
                "type": "tool_result",
                "content": "1\thello world\n2\t",
            }
        ],
    },
}

ASSISTANT_TEXT_EVENT = {
    "type": "assistant",
    "session_id": SESSION,
    "message": {
        "role": "assistant",
        "content": [
            {
                "type": "text",
                "text": "The word that follows hello is world.",
            }
        ],
    },
}

RESULT_EVENT = {
    "type": "result",
    "subtype": "success",
    "is_error": False,
    "result": "The word that follows hello is world.",
    "session_id": SESSION,
}


def _run(events: list[dict]) -> tuple[list[StreamTool], StreamReply]:
    acc = StreamAccumulator()
    live: list[StreamTool] = []
    for ev in events:
        tool = acc.feed(ev)
        if tool is not None:
            live.append(tool)
    return live, acc.result()


def test_full_turn_extracts_tool_and_final_reply():
    events = [
        INIT_EVENT,
        ASSISTANT_THINKING_EVENT,
        ASSISTANT_TOOL_USE_EVENT,
        USER_TOOL_RESULT_EVENT,
        ASSISTANT_TEXT_EVENT,
        RESULT_EVENT,
    ]
    live, reply = _run(events)

    # One live tool preview emitted from the tool_use block.
    assert len(live) == 1
    assert live[0].name == "Read"
    assert live[0].preview == "file_path='/tmp/sample.txt'"

    # Final authoritative reply: text from the result event, session from init.
    assert isinstance(reply, StreamReply)
    assert reply.text == "The word that follows hello is world."
    assert reply.session_id == SESSION

    # The tool was recorded and marked ok (no is_error on the tool_result).
    assert len(reply.tools) == 1
    assert reply.tools[0].name == "Read"
    assert reply.tools[0].preview == "file_path='/tmp/sample.txt'"
    assert reply.tools[0].ok is True


def test_session_id_sourced_from_init_event():
    acc = StreamAccumulator()
    acc.feed(INIT_EVENT)
    assert acc.session_id == SESSION


def test_tool_result_error_flips_ok_false():
    failed_result = {
        "type": "user",
        "session_id": SESSION,
        "message": {
            "role": "user",
            "content": [
                {
                    "tool_use_id": TOOL_USE_ID,
                    "type": "tool_result",
                    "is_error": True,
                    "content": "File not found",
                }
            ],
        },
    }
    _live, reply = _run(
        [INIT_EVENT, ASSISTANT_TOOL_USE_EVENT, failed_result, RESULT_EVENT]
    )
    assert len(reply.tools) == 1
    assert reply.tools[0].ok is False


def test_thinking_and_partial_events_are_ignored_for_tools():
    # Thinking blocks and bare init events must not produce StreamTools.
    assert parse_event(INIT_EVENT) is None
    assert parse_event(ASSISTANT_THINKING_EVENT) is None


def test_no_tool_turn_still_yields_text_reply():
    # A plain "hello" turn: init, assistant text, result — no tools.
    events = [INIT_EVENT, ASSISTANT_TEXT_EVENT, RESULT_EVENT]
    live, reply = _run(events)
    assert live == []
    assert reply.text == "The word that follows hello is world."
    assert reply.session_id == SESSION
    assert reply.tools == []


def test_result_event_text_overrides_accumulated_assistant_text():
    # The terminal result is authoritative even if an earlier assistant text
    # block differs.
    early_text = dict(ASSISTANT_TEXT_EVENT)
    early_text["message"] = {
        "role": "assistant",
        "content": [{"type": "text", "text": "partial draft"}],
    }
    _live, reply = _run([INIT_EVENT, early_text, RESULT_EVENT])
    assert reply.text == "The word that follows hello is world."


def test_parse_oneshot_extracts_result_and_session():
    # Real one-shot `--output-format json` shape (trimmed).
    line = (
        '{"type":"result","subtype":"success","is_error":false,'
        '"result":"hello","session_id":"3fdf5fbc-e2d9-46a6-92b6-3be6ee39d8c5"}'
    )
    reply = _parse_oneshot(line)
    assert reply.text == "hello"
    assert reply.session_id == "3fdf5fbc-e2d9-46a6-92b6-3be6ee39d8c5"


def test_parse_compact_success_preserves_session_id():
    # In-place compaction returns the SAME session_id and is_error=false.
    line = (
        '{"type":"result","subtype":"success","is_error":false,'
        f'"result":"Compacted.","session_id":"{SESSION}"}}'
    )
    out = _parse_compact(line, SESSION)
    assert out["ok"] is True
    assert out["session_id"] == SESSION  # preserved, no fork
    assert out["message"]


def test_parse_compact_no_session_id_falls_back_to_input():
    # If the result omits session_id, we fall back to the resumed id.
    line = '{"type":"result","is_error":false,"result":"ok"}'
    out = _parse_compact(line, SESSION)
    assert out["ok"] is True
    assert out["session_id"] == SESSION


def test_parse_compact_not_enough_messages_is_friendly_not_error():
    # The "not enough messages" case maps to a friendly ok=False message.
    line = (
        '{"type":"result","subtype":"error","is_error":true,'
        '"result":"Error: not enough messages to compact",'
        f'"session_id":"{SESSION}"}}'
    )
    out = _parse_compact(line, SESSION)
    assert out["ok"] is False
    assert "nothing to compact" in out["message"].lower()
    assert out["session_id"] == SESSION
