"""OpenAI TTS provider (tts-1, tts-1-hd, gpt-4o-mini-tts)."""
from __future__ import annotations

import httpx

from . import TTSResult


class OpenAITTS:
    name = "openai_tts"
    stream_extension = ".mp3"
    stream_mime = "audio/mpeg"

    def __init__(self, api_key: str, model: str = "tts-1", voice: str = "onyx"):
        self._key = api_key
        self._model = model
        self._voice = voice

    def describe(self) -> dict:
        return {"name": self.name, "model": self._model, "voice": self._voice}

    async def stream(self, text: str):
        result = await self.synthesize(text)
        yield result.audio

    async def synthesize(self, text: str) -> TTSResult:
        async with httpx.AsyncClient(timeout=60.0) as client:
            resp = await client.post(
                "https://api.openai.com/v1/audio/speech",
                headers={
                    "Authorization": f"Bearer {self._key}",
                    "Content-Type": "application/json",
                },
                json={
                    "model": self._model,
                    "voice": self._voice,
                    "input": text,
                    "response_format": "mp3",
                },
            )
        resp.raise_for_status()
        return TTSResult(audio=resp.content, mime="audio/mpeg", extension=".mp3")
