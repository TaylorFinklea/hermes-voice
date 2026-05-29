"""Tests for the SSE streaming turn endpoints."""
from __future__ import annotations

import json

from .conftest import FakeHermes, FakeTTS, build_client


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


def test_text_stream_rejects_malformed_voice_id():
    # Boundary validation still applies on the streaming endpoint.
    client = build_client(hermes=FakeHermes(), tts=FakeTTS())
    resp = client.post("/api/text/stream", json={"text": "hi", "voice_id": "../bad"})
    assert resp.status_code == 422
