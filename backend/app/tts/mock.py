"""Mock TTS — returns a tiny valid WAV file so the iOS player has *something*.

The audio is ~250ms of silence at 16kHz mono. Real enough to play, fake enough
to not be confused for actual speech.
"""
from __future__ import annotations

import io
import wave

from . import TTSResult


def _silent_wav(duration_s: float = 0.25, sample_rate: int = 16000) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(sample_rate)
        wav.writeframes(b"\x00\x00" * int(sample_rate * duration_s))
    return buf.getvalue()


class MockTTS:
    name = "mock"
    stream_extension = ".wav"
    stream_mime = "audio/wav"

    def __init__(self):
        self._audio = _silent_wav()

    def describe(self) -> dict:
        return {"name": self.name, "format": "silent_wav"}

    async def synthesize(self, text: str, voice_id: str | None = None) -> TTSResult:
        return TTSResult(audio=self._audio, mime="audio/wav", extension=".wav")

    async def stream(self, text: str, voice_id: str | None = None):
        yield self._audio
