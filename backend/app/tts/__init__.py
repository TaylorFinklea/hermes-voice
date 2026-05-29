"""Text-to-speech provider abstraction.

Selection rules (first non-empty wins):
1. TTS_PROVIDER env override
2. ELEVENLABS_API_KEY → elevenlabs
3. OPENAI_API_KEY / VOICE_TOOLS_OPENAI_KEY → openai
4. PIPER_VOICE_PATH (with `pip install '.[local]'`) → piper
5. mock (silent placeholder)

All providers expose `synthesize()` (returns the full audio at once) and
`stream()` (yields chunks as they're generated). Providers that don't have
real streaming get a wrapper that yields one big chunk. ElevenLabs has a
genuine streaming endpoint and overrides `stream()` for the latency win.
"""
from __future__ import annotations

from collections.abc import AsyncIterator
from dataclasses import dataclass
from typing import Protocol

from ..config import Settings


@dataclass(frozen=True)
class TTSResult:
    audio: bytes
    mime: str
    extension: str  # e.g. ".mp3", ".wav"


class TTSProvider(Protocol):
    name: str

    async def synthesize(self, text: str, voice_id: str | None = None) -> TTSResult: ...

    def describe(self) -> dict: ...

    async def stream(self, text: str, voice_id: str | None = None) -> AsyncIterator[bytes]:
        """Yield audio chunks as they're synthesized.

        Default fallback: calls synthesize() and yields the whole thing
        as one chunk. Override for real streaming. `voice_id` overrides the
        provider's default voice when supported (ElevenLabs); others ignore it.
        """
        result = await self.synthesize(text, voice_id=voice_id)
        yield result.audio

    @property
    def stream_extension(self) -> str:
        return ".mp3"

    @property
    def stream_mime(self) -> str:
        return "audio/mpeg"


def make_tts(settings: Settings) -> TTSProvider | None:
    override = (settings.tts_provider_override or "").strip().lower()

    if settings.mock or override == "mock":
        from .mock import MockTTS
        return MockTTS()

    if override == "elevenlabs" or (not override and settings.elevenlabs_key):
        if settings.elevenlabs_key:
            from .elevenlabs import ElevenLabsTTS
            return ElevenLabsTTS(
                api_key=settings.elevenlabs_key,
                voice_id=settings.elevenlabs_voice_id,
                model=settings.elevenlabs_model,
            )

    if override == "openai" or (not override and settings.openai_key):
        if settings.openai_key:
            from .openai_tts import OpenAITTS
            return OpenAITTS(
                api_key=settings.openai_key,
                model=settings.openai_tts_model,
                voice=settings.openai_tts_voice,
            )

    if override in {"", "piper", "local", "local_piper"}:
        if settings.piper_voice_path:
            try:
                from .piper_tts import PiperTTS
            except ImportError:
                if override:
                    raise
                return None
            return PiperTTS(voice_path=settings.piper_voice_path)

    return None
