"""ElevenLabs TTS provider, with HTTP-streaming support.

We use two endpoints:
- /text-to-speech/{voice}            — non-streaming, returns complete MP3
- /text-to-speech/{voice}/stream     — chunked MP3, low time-to-first-byte

The streaming variant is what powers the iOS app's progressive playback:
audio starts playing within ~300ms instead of waiting for full synthesis.
"""
from __future__ import annotations

from collections.abc import AsyncIterator

import httpx

from . import TTSResult


class ElevenLabsTTS:
    name = "elevenlabs"
    stream_extension = ".mp3"
    stream_mime = "audio/mpeg"

    def __init__(
        self,
        api_key: str,
        voice_id: str,
        model: str = "eleven_turbo_v2_5",
    ):
        self._key = api_key
        self._voice = voice_id
        self._model = model

    def describe(self) -> dict:
        return {"name": self.name, "voice_id": self._voice, "model": self._model}

    def _body(self, text: str) -> dict:
        return {
            "text": text,
            "model_id": self._model,
            "voice_settings": {
                "stability": 0.45,
                "similarity_boost": 0.75,
                "style": 0.0,
                "use_speaker_boost": True,
            },
        }

    def _headers(self) -> dict:
        return {
            "xi-api-key": self._key,
            "Accept": "audio/mpeg",
            "Content-Type": "application/json",
        }

    async def synthesize(self, text: str) -> TTSResult:
        url = f"https://api.elevenlabs.io/v1/text-to-speech/{self._voice}"
        async with httpx.AsyncClient(timeout=60.0) as client:
            resp = await client.post(url, headers=self._headers(), json=self._body(text))
        resp.raise_for_status()
        return TTSResult(audio=resp.content, mime="audio/mpeg", extension=".mp3")

    async def stream(self, text: str) -> AsyncIterator[bytes]:
        """HTTP-streaming MP3 from ElevenLabs `/stream` endpoint.

        Yields chunks as ElevenLabs produces them, which is roughly real-time:
        first chunk lands in ~200-400ms, subsequent chunks at speech-rate.
        """
        url = f"https://api.elevenlabs.io/v1/text-to-speech/{self._voice}/stream"
        async with httpx.AsyncClient(timeout=60.0) as client:
            async with client.stream(
                "POST", url, headers=self._headers(), json=self._body(text)
            ) as resp:
                resp.raise_for_status()
                async for chunk in resp.aiter_bytes():
                    if chunk:
                        yield chunk
