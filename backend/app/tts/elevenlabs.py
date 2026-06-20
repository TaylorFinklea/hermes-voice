"""ElevenLabs TTS provider, with HTTP-streaming support.

We use two endpoints:
- /text-to-speech/{voice}            — non-streaming, returns complete MP3
- /text-to-speech/{voice}/stream     — chunked MP3, low time-to-first-byte

The streaming variant is what powers the iOS app's progressive playback:
audio starts playing within ~300ms instead of waiting for full synthesis.
"""
from __future__ import annotations

import re
from collections.abc import AsyncIterator

import httpx

from .._http import acquire_client
from . import TTSResult

# ElevenLabs voice ids are short alphanumerics (e.g. "nPczCjzI2devNBz1zQrb").
# Anything outside this set (slashes, dots, query/encoded chars) could rewrite
# the request path, so a caller-supplied id is never interpolated raw — see
# ElevenLabsTTS._resolve_voice.
_SAFE_VOICE = re.compile(r"\A[A-Za-z0-9_-]{1,64}\Z")


class ElevenLabsTTS:
    name = "elevenlabs"
    stream_extension = ".mp3"
    stream_mime = "audio/mpeg"

    def __init__(
        self,
        api_key: str,
        voice_id: str,
        model: str = "eleven_turbo_v2_5",
        client: httpx.AsyncClient | None = None,
    ):
        self._key = api_key
        self._voice = voice_id
        self._model = model
        self._client = client

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

    def _resolve_voice(self, voice_id: str | None) -> str:
        """Whitelist the caller-supplied voice id; fall back to the configured
        default if it's missing or not a plain voice id. Prevents path/SSRF
        injection from a value that contains slashes or other URL metacharacters.
        """
        if voice_id and _SAFE_VOICE.match(voice_id):
            return voice_id
        return self._voice

    async def synthesize(self, text: str, voice_id: str | None = None) -> TTSResult:
        voice = self._resolve_voice(voice_id)
        url = f"https://api.elevenlabs.io/v1/text-to-speech/{voice}"
        async with acquire_client(self._client, timeout=60.0) as client:
            resp = await client.post(
                url, headers=self._headers(), json=self._body(text), timeout=60.0
            )
        resp.raise_for_status()
        return TTSResult(audio=resp.content, mime="audio/mpeg", extension=".mp3")

    async def stream(self, text: str, voice_id: str | None = None) -> AsyncIterator[bytes]:
        """HTTP-streaming MP3 from ElevenLabs `/stream` endpoint.

        Yields chunks as ElevenLabs produces them, which is roughly real-time:
        first chunk lands in ~200-400ms, subsequent chunks at speech-rate.
        """
        voice = self._resolve_voice(voice_id)
        url = f"https://api.elevenlabs.io/v1/text-to-speech/{voice}/stream"
        async with acquire_client(self._client, timeout=60.0) as client:
            async with client.stream(
                "POST", url, headers=self._headers(), json=self._body(text), timeout=60.0
            ) as resp:
                resp.raise_for_status()
                async for chunk in resp.aiter_bytes():
                    if chunk:
                        yield chunk
