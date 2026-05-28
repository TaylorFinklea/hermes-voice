"""ElevenLabs Scribe STT provider (batch, non-streaming).

Scribe v1 is ElevenLabs' general-purpose speech-to-text model. It returns
JSON with the full transcript plus per-word timestamps. We only use the
top-level `text` field for now; word timestamps are a roadmap item for
showing live highlighting in the transcript.

Realtime Scribe v2 exists as a streaming WebSocket endpoint — that's the
swap-in target when we add streaming STT (see roadmap).

Docs: https://elevenlabs.io/docs/api-reference/speech-to-text/convert
"""
from __future__ import annotations

import httpx

from .openai_stt import _guess_filename_and_type


class ElevenLabsScribeSTT:
    name = "elevenlabs_scribe"

    def __init__(self, api_key: str, model: str = "scribe_v1"):
        self._key = api_key
        self._model = model

    def describe(self) -> dict:
        return {"name": self.name, "model": self._model}

    async def transcribe(self, audio_bytes: bytes, *, mime: str | None = None) -> str:
        filename, content_type = _guess_filename_and_type(mime)
        async with httpx.AsyncClient(timeout=90.0) as client:
            resp = await client.post(
                "https://api.elevenlabs.io/v1/speech-to-text",
                headers={"xi-api-key": self._key},
                data={"model_id": self._model},
                files={"file": (filename, audio_bytes, content_type)},
            )
        resp.raise_for_status()
        body = resp.json()
        # Response shape: {"text": "...", "language_code": "...", "words": [...]}
        text = body.get("text", "").strip()
        return text
