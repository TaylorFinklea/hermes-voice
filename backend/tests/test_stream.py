"""Tests for the SSE streaming turn endpoints."""
from __future__ import annotations

import json

from app.hermes import HermesClient, HermesReply, StreamNarration, StreamReply, StreamTool
from app.session_audit import ToolCallSummary

from .conftest import FakeHermes, FakeTTS, build_client


class NarratingHermes(HermesClient):
    """Fake hermes that yields a StreamNarration alongside its tool event, like
    the warm ACP path does. Mirrors conftest.FakeHermes."""

    def __init__(self, reply: str = "Done."):
        self._reply = reply

    def is_available(self) -> bool:
        return True

    def describe(self) -> dict:
        return {"bin": "fake-narrating", "available": True}

    async def ask(self, prompt: str, session_id: str | None = None) -> HermesReply:
        return HermesReply(text=self._reply, session_id=session_id or "fake-session-1")

    async def ask_streaming(self, prompt: str, session_id: str | None = None):
        yield StreamTool(name="terminal", preview="$ echo hi")
        yield StreamNarration(text="Alright, let me run that.")
        yield StreamReply(
            text=self._reply,
            session_id=session_id or "fake-session-1",
            tools=[ToolCallSummary(name="terminal", preview="$ echo hi", ok=True)],
        )


def _parse_sse(body: str) -> list[dict]:
    events: list[dict] = []
    for line in body.splitlines():
        line = line.strip()
        if line.startswith("data:"):
            events.append(json.loads(line[len("data:"):].strip()))
    return events


def test_text_stream_emits_ordered_events():
    client = build_client(hermes=FakeHermes(reply="hi there"), tts=FakeTTS())
    with client.stream("POST", "/api/text/stream", json={"text": "hello"}) as resp:
        assert resp.status_code == 200
        body = "".join(resp.iter_text())

    events = _parse_sse(body)
    types = [e["type"] for e in events]
    assert types[0] == "transcribed"
    assert "tool" in types            # a live tool event streamed
    assert "tools" in types           # authoritative reconciled list
    assert "assistant" in types
    assert types[-1] == "done"

    assistant = next(e for e in events if e["type"] == "assistant")
    assert assistant["text"] == "hi there"
    assert assistant["session_id"]

    audio = next(e for e in events if e["type"] == "audio")
    assert audio["url"].startswith("/api/audio/")


def test_text_stream_tool_events_present_and_reconciled():
    client = build_client(hermes=FakeHermes(), tts=FakeTTS())
    with client.stream("POST", "/api/text/stream", json={"text": "do something"}) as resp:
        body = "".join(resp.iter_text())

    events = _parse_sse(body)
    live = [e for e in events if e["type"] == "tool"]
    auth = next(e for e in events if e["type"] == "tools")
    assert live and live[0]["name"] == "terminal"
    assert auth["items"] and auth["items"][0]["name"] == "terminal"


def test_text_stream_emits_narrate_frame_for_tool_turn():
    # A tool-using turn emits an additive `narrate` SSE frame (spoken filler),
    # interleaved with the live tool frames. iOS speaks it via AVSpeech.
    client = build_client(hermes=NarratingHermes(reply="Done."), tts=FakeTTS())
    with client.stream("POST", "/api/text/stream", json={"text": "run it"}) as resp:
        assert resp.status_code == 200
        body = "".join(resp.iter_text())

    events = _parse_sse(body)
    narrate = next(e for e in events if e["type"] == "narrate")
    assert narrate["text"].strip()
    # Existing frames still flow and stay ordered.
    types = [e["type"] for e in events]
    assert types[0] == "transcribed"
    assert "assistant" in types
    assert types[-1] == "done"


def test_text_stream_rejects_malformed_voice_id():
    # Boundary validation still applies on the streaming endpoint.
    client = build_client(hermes=FakeHermes(), tts=FakeTTS())
    resp = client.post("/api/text/stream", json={"text": "hi", "voice_id": "../bad"})
    assert resp.status_code == 422


def test_text_stream_tts_none_skips_audio_event():
    # tts=none → the client will speak the reply on-device, so the server
    # must NOT synthesize or emit an `audio` event. The assistant + done
    # events still flow.
    client = build_client(hermes=FakeHermes(reply="hi there"), tts=FakeTTS())
    with client.stream(
        "POST", "/api/text/stream", json={"text": "hello", "tts": "none"}
    ) as resp:
        assert resp.status_code == 200
        body = "".join(resp.iter_text())

    types = [e["type"] for e in _parse_sse(body)]
    assert "assistant" in types
    assert "audio" not in types
    assert types[-1] == "done"


def test_text_turn_tts_none_returns_no_audio_url():
    # Same contract on the non-streaming fallback: no audio_url when tts=none.
    client = build_client(hermes=FakeHermes(reply="hi there"), tts=FakeTTS())
    resp = client.post("/api/text", json={"text": "hello", "tts": "none"})
    assert resp.status_code == 200
    body = resp.json()
    assert body["assistant_text"] == "hi there"
    assert body["audio_url"] is None


def test_text_stream_rejects_bad_tts_value():
    # Only the documented modes are accepted.
    client = build_client(hermes=FakeHermes(), tts=FakeTTS())
    resp = client.post("/api/text/stream", json={"text": "hi", "tts": "bogus"})
    assert resp.status_code == 422
