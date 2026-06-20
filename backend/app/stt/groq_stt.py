"""Groq Whisper-large-v3 STT provider (very fast, OpenAI-compatible API)."""
from __future__ import annotations

import httpx

from .._http import acquire_client
from .openai_stt import _guess_filename_and_type


class GroqSTT:
    name = "groq_whisper"

    def __init__(
        self,
        api_key: str,
        model: str = "whisper-large-v3-turbo",
        client: httpx.AsyncClient | None = None,
    ):
        self._key = api_key
        self._model = model
        self._client = client

    def describe(self) -> dict:
        return {"name": self.name, "model": self._model}

    async def transcribe(self, audio_bytes: bytes, *, mime: str | None = None) -> str:
        filename, content_type = _guess_filename_and_type(mime)
        async with acquire_client(self._client, timeout=60.0) as client:
            resp = await client.post(
                "https://api.groq.com/openai/v1/audio/transcriptions",
                headers={"Authorization": f"Bearer {self._key}"},
                data={"model": self._model, "response_format": "text"},
                files={"file": (filename, audio_bytes, content_type)},
                timeout=60.0,
            )
        resp.raise_for_status()
        return resp.text.strip()
