"""Mock STT — returns a canned transcription without touching audio."""
from __future__ import annotations


class MockSTT:
    name = "mock"

    def describe(self) -> dict:
        return {"name": self.name, "model": "canned"}

    async def transcribe(self, audio_bytes: bytes, *, mime: str | None = None) -> str:
        size_kb = len(audio_bytes) // 1024
        return f"[mock transcription of {size_kb}KB audio]"
