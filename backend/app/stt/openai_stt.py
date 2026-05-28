"""OpenAI Whisper API STT provider."""
from __future__ import annotations

import httpx


class OpenAISTT:
    name = "openai_whisper"

    def __init__(self, api_key: str, model: str = "whisper-1"):
        self._key = api_key
        self._model = model

    def describe(self) -> dict:
        return {"name": self.name, "model": self._model}

    async def transcribe(self, audio_bytes: bytes, *, mime: str | None = None) -> str:
        filename, content_type = _guess_filename_and_type(mime)
        async with httpx.AsyncClient(timeout=60.0) as client:
            resp = await client.post(
                "https://api.openai.com/v1/audio/transcriptions",
                headers={"Authorization": f"Bearer {self._key}"},
                data={"model": self._model, "response_format": "text"},
                files={"file": (filename, audio_bytes, content_type)},
            )
        resp.raise_for_status()
        # response_format=text returns plain text body
        return resp.text.strip()


def _guess_filename_and_type(mime: str | None) -> tuple[str, str]:
    if not mime:
        return "audio.m4a", "audio/m4a"
    if "wav" in mime:
        return "audio.wav", "audio/wav"
    if "mp3" in mime or "mpeg" in mime:
        return "audio.mp3", "audio/mpeg"
    if "ogg" in mime or "opus" in mime:
        return "audio.ogg", "audio/ogg"
    if "webm" in mime:
        return "audio.webm", "audio/webm"
    return "audio.m4a", mime
