"""Tests for the voice-picker endpoint + per-request voice override."""
from __future__ import annotations

from app.tts import TTSResult

from .conftest import FakeTTS, build_client


def test_voices_empty_when_provider_has_no_catalog():
    # FakeTTS has no list_voices() → endpoint returns [] so the iOS picker
    # falls back to the server default.
    client = build_client(tts=FakeTTS())
    resp = client.get("/api/voices")
    assert resp.status_code == 200
    assert resp.json() == []


class _CatalogTTS(FakeTTS):
    async def list_voices(self):
        return [
            {"voice_id": "v1", "name": "Onyx", "category": "premade"},
            {"voice_id": "v2", "name": "Custom"},  # category omitted → null
        ]


def test_voices_returns_catalog():
    client = build_client(tts=_CatalogTTS())
    resp = client.get("/api/voices")
    assert resp.status_code == 200
    body = resp.json()
    assert [v["voice_id"] for v in body] == ["v1", "v2"]
    assert body[0]["name"] == "Onyx"
    assert body[0]["category"] == "premade"
    assert body[1]["category"] is None


class _RecordingTTS(FakeTTS):
    def __init__(self):
        super().__init__()
        self.voice_ids: list[str | None] = []

    async def synthesize(self, text: str, voice_id: str | None = None) -> TTSResult:
        self.voice_ids.append(voice_id)
        return TTSResult(audio=b"FAKE", mime="audio/wav", extension=".wav")

    async def stream(self, text: str, voice_id: str | None = None):
        self.voice_ids.append(voice_id)
        yield b"FA"
        yield b"KE"


def test_text_turn_passes_voice_id_through_to_tts():
    tts = _RecordingTTS()
    client = build_client(tts=tts)
    resp = client.post("/api/text", json={"text": "hi", "voice_id": "v-custom"})
    assert resp.status_code == 200
    audio_url = resp.json()["audio_url"]
    assert audio_url
    # Draining the audio stream forces the background producer (and thus
    # tts.stream) to actually run.
    audio = client.get(audio_url)
    assert audio.status_code == 200
    assert tts.voice_ids == ["v-custom"]


def test_replay_passes_voice_id_through_to_tts():
    tts = _RecordingTTS()
    client = build_client(tts=tts)
    resp = client.post("/api/replay", json={"text": "again", "voice_id": "v-other"})
    assert resp.status_code == 200
    audio_url = resp.json()["audio_url"]
    assert audio_url
    client.get(audio_url)
    assert tts.voice_ids == ["v-other"]
