"""Local faster-whisper STT provider.

Requires `pip install '.[local]'`. Models auto-download on first use to
~/.cache/huggingface/. On Apple Silicon, faster-whisper runs on CPU
(Metal isn't supported by CTranslate2 yet); it's still fast for short
utterances thanks to int8 quantization.

TODO: swap in NVIDIA Parakeet (via parakeet-mlx or NeMo) once a turn-key
Apple Silicon path stabilizes — currently faster-whisper is the smoother
local option.
"""
from __future__ import annotations

import asyncio
import tempfile

try:
    from faster_whisper import WhisperModel
except ImportError as e:
    raise ImportError(
        "faster-whisper is not installed. Install with: pip install '.[local]'"
    ) from e


class LocalWhisperSTT:
    name = "local_whisper"

    def __init__(self, model: str = "base.en", device: str = "auto"):
        compute_type = "int8" if device in {"auto", "cpu"} else "float16"
        actual_device = "cpu" if device == "auto" else device
        self._model_name = model
        self._device = actual_device
        self._model = WhisperModel(model, device=actual_device, compute_type=compute_type)

    def describe(self) -> dict:
        return {"name": self.name, "model": self._model_name, "device": self._device}

    async def transcribe(self, audio_bytes: bytes, *, mime: str | None = None) -> str:
        # faster-whisper wants a file path or numpy array. Use a temp file —
        # works for any container ffmpeg can decode (m4a, wav, mp3, ...).
        suffix = _suffix_for_mime(mime)
        return await asyncio.to_thread(self._transcribe_sync, audio_bytes, suffix)

    def _transcribe_sync(self, audio_bytes: bytes, suffix: str) -> str:
        with tempfile.NamedTemporaryFile(suffix=suffix, delete=True) as f:
            f.write(audio_bytes)
            f.flush()
            segments, _info = self._model.transcribe(f.name, beam_size=1, vad_filter=True)
            return " ".join(seg.text.strip() for seg in segments).strip()


def _suffix_for_mime(mime: str | None) -> str:
    if not mime:
        return ".m4a"
    if "wav" in mime:
        return ".wav"
    if "mp3" in mime or "mpeg" in mime:
        return ".mp3"
    if "ogg" in mime or "opus" in mime:
        return ".ogg"
    if "webm" in mime:
        return ".webm"
    return ".m4a"
