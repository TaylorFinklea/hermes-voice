"""Groq Whisper-large-v3 STT provider (very fast, OpenAI-compatible API)."""
from __future__ import annotations

import httpx

from .openai_stt import _guess_filename_and_type


class GroqSTT:
    name = "groq_whisper"

    def __init__(self, api_key: str, model: str = "whisper-large-v3-turbo"):
        self._key = api_key
        self._model = model

    def describe(self) -> dict:
        return {"name": self.name, "model": self._model}

    async def transcribe(self, audio_bytes: bytes, *, mime: str | None = None) -> str:
        filename, content_type = _guess_filename_and_type(mime)
        async with httpx.AsyncClient(timeout=60.0) as client:
            resp = await client.post(
                "https://api.groq.com/openai/v1/audio/transcriptions",
                headers={"Authorization": f"Bearer {self._key}"},
                data={"model": self._model, "response_format": "text"},
                files={"file": (filename, audio_bytes, content_type)},
            )
        resp.raise_for_status()
        return resp.text.strip()
