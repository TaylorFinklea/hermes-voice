"""Shared test fixtures.

Each test gets a fresh FastAPI app with explicitly-injected fakes so we never
hit network or the real hermes binary.
"""
from __future__ import annotations

from dataclasses import dataclass

import pytest
from fastapi.testclient import TestClient

from app.audio_store import AudioStore
from app.config import reset_settings_cache
from app.hermes import HermesClient, HermesReply
from app.main import create_app
from app.tts import TTSResult


@dataclass
class FakeHermes(HermesClient):
    """No-subprocess hermes that records calls."""

    def __init__(self, reply: str = "fake reply"):
        self._reply = reply
        self.calls: list[tuple[str, str | None]] = []

    def is_available(self) -> bool:
        return True

    def describe(self) -> dict:
        return {"bin": "fake", "available": True}

    async def ask(self, prompt: str, session_id: str | None = None) -> HermesReply:
        self.calls.append((prompt, session_id))
        return HermesReply(text=self._reply, session_id=session_id or "fake-session-1")


class FakeTTS:
    name = "fake_tts"
    stream_extension = ".wav"
    stream_mime = "audio/wav"

    def __init__(self):
        self.calls: list[str] = []

    def describe(self) -> dict:
        return {"name": self.name}

    async def synthesize(self, text: str, voice_id: str | None = None) -> TTSResult:
        self.calls.append(text)
        # 4 bytes of fake audio — enough to round-trip through the store.
        return TTSResult(audio=b"FAKE", mime="audio/wav", extension=".wav")

    async def stream(self, text: str, voice_id: str | None = None):
        self.calls.append(text)
        # Emit in two chunks to exercise the streaming path.
        yield b"FA"
        yield b"KE"


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch):
    """Strip env so tests run deterministically regardless of host config."""
    for var in (
        "HERMES_VOICE_MOCK", "HERMES_VOICE_TOKEN",
        "OPENAI_API_KEY", "VOICE_TOOLS_OPENAI_KEY", "GROQ_API_KEY",
        "ELEVENLABS_API_KEY", "STT_PROVIDER", "TTS_PROVIDER",
        "PIPER_VOICE_PATH", "HERMES_EXTRA_ARGS",
    ):
        monkeypatch.delenv(var, raising=False)
    reset_settings_cache()
    yield
    reset_settings_cache()


def build_client(*, hermes=None, stt=None, tts=None) -> TestClient:
    app = create_app(
        hermes=hermes if hermes is not None else FakeHermes(),
        stt=stt,
        tts=tts,
        store=AudioStore(max_items=4),
    )
    return TestClient(app)


__all__ = ["FakeHermes", "FakeTTS", "build_client"]
