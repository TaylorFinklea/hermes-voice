"""Speech-to-text provider abstraction.

Auto-selection rules (first non-empty wins):
1. STT_PROVIDER env override (openai | groq | elevenlabs | local_whisper | mock)
2. OPENAI_API_KEY / VOICE_TOOLS_OPENAI_KEY → openai
3. GROQ_API_KEY → groq
4. ELEVENLABS_API_KEY → elevenlabs (Scribe v1)
5. local faster-whisper if installed
6. mock (always available)

To A/B test Scribe against OpenAI without removing your OpenAI key,
set STT_PROVIDER=elevenlabs in .env.
"""
from __future__ import annotations

from typing import Protocol

import httpx

from ..config import Settings


class STTProvider(Protocol):
    name: str

    async def transcribe(self, audio_bytes: bytes, *, mime: str | None = None) -> str: ...

    def describe(self) -> dict: ...


class STTNotConfiguredError(RuntimeError):
    """No usable STT provider; /api/audio cannot proceed."""


def make_stt(
    settings: Settings, client: httpx.AsyncClient | None = None
) -> STTProvider | None:
    """Return the best available STT provider, or None.

    Returns None only if mock mode is off AND no provider can serve.
    Callers should treat None as 'no STT available' and surface a clear error.
    """
    override = (settings.stt_provider_override or "").strip().lower()

    if settings.mock or override == "mock":
        from .mock import MockSTT
        return MockSTT()

    if override == "openai" or (not override and settings.openai_key):
        if settings.openai_key:
            from .openai_stt import OpenAISTT
            return OpenAISTT(settings.openai_key, client=client)

    if override == "groq" or (not override and settings.groq_key):
        if settings.groq_key:
            from .groq_stt import GroqSTT
            return GroqSTT(settings.groq_key, client=client)

    if override == "elevenlabs" or (not override and settings.elevenlabs_key):
        if settings.elevenlabs_key:
            from .elevenlabs_scribe import ElevenLabsScribeSTT
            return ElevenLabsScribeSTT(settings.elevenlabs_key, client=client)

    if override in {"", "local", "local_whisper", "faster_whisper"}:
        try:
            from .local_whisper import LocalWhisperSTT
        except ImportError:
            if override:  # they asked for it explicitly
                raise
            return None
        return LocalWhisperSTT(
            model=settings.local_whisper_model,
            device=settings.local_whisper_device,
        )

    return None
