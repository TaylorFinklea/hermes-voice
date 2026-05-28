"""Local Piper TTS provider.

Requires `pip install '.[local]'` and a downloaded voice model.
Get voices here: https://huggingface.co/rhasspy/piper-voices

Recommended masculine voices (download .onnx + .onnx.json side-by-side):
  - en_US-ryan-high
  - en_GB-alan-medium
  - en_US-lessac-medium  (more neutral)

Then set PIPER_VOICE_PATH to the .onnx file's absolute path.

Piper outputs raw PCM; we wrap it in a WAV container so iOS plays it directly.
"""
from __future__ import annotations

import asyncio
import io
import wave
from pathlib import Path

try:
    from piper import PiperVoice
except ImportError as e:
    raise ImportError(
        "piper-tts is not installed. Install with: pip install '.[local]'"
    ) from e

from . import TTSResult


class PiperTTS:
    name = "local_piper"
    stream_extension = ".wav"
    stream_mime = "audio/wav"

    async def stream(self, text: str):
        result = await self.synthesize(text)
        yield result.audio

    def __init__(self, voice_path: str):
        path = Path(voice_path).expanduser().resolve()
        if not path.exists():
            raise FileNotFoundError(f"Piper voice not found: {path}")
        self._path = path
        self._voice = PiperVoice.load(str(path))

    def describe(self) -> dict:
        return {"name": self.name, "voice_path": str(self._path)}

    async def synthesize(self, text: str) -> TTSResult:
        return await asyncio.to_thread(self._synthesize_sync, text)

    def _synthesize_sync(self, text: str) -> TTSResult:
        buf = io.BytesIO()
        with wave.open(buf, "wb") as wav:
            self._voice.synthesize(text, wav)
        return TTSResult(audio=buf.getvalue(), mime="audio/wav", extension=".wav")
