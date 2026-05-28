"""Short-lived store for synthesized audio served by /api/audio/{id}.

Two modes per audio_id:

1. **Completed file** — created via `put(bytes, ext)`. Served as a FileResponse.
   Used by non-streaming TTS providers and the audio cache.

2. **Live stream** — created via `start_stream(ext, mime)`, returns (audio_id,
   push_queue). A producer task pushes chunks onto the queue; consumers
   (the HTTP handler) await chunks via `iter_chunks(audio_id)` and yield them
   to the client as they arrive. The producer signals end-of-stream by
   pushing None onto the queue.

Both modes evict FIFO once we exceed the cap.
"""
from __future__ import annotations

import asyncio
import secrets
import threading
import time
from collections import OrderedDict
from collections.abc import AsyncIterator
from dataclasses import dataclass, field
from pathlib import Path
from tempfile import mkdtemp


@dataclass
class _LiveStream:
    queue: asyncio.Queue
    extension: str
    mime: str
    started_at: float
    done: bool = False
    # Accumulated bytes — kept so the URL can be re-fetched after the stream
    # ends (e.g. iOS app backgrounded mid-stream and resumed).
    buffered: bytearray = field(default_factory=bytearray)


class AudioStore:
    def __init__(self, max_items: int = 64):
        self._dir = Path(mkdtemp(prefix="hermes-voice-"))
        self._max = max_items
        self._files: OrderedDict[str, Path] = OrderedDict()
        self._streams: OrderedDict[str, _LiveStream] = OrderedDict()
        self._lock = threading.Lock()

    @property
    def root(self) -> Path:
        return self._dir

    def put(self, audio: bytes, extension: str) -> str:
        """Store a complete audio blob and return its id (for FileResponse)."""
        if not extension.startswith("."):
            extension = "." + extension
        audio_id = secrets.token_urlsafe(12)
        path = self._dir / f"{audio_id}{extension}"
        path.write_bytes(audio)
        with self._lock:
            self._files[audio_id] = path
            self._evict_files()
        return audio_id

    def start_stream(self, extension: str, mime: str) -> tuple[str, asyncio.Queue]:
        """Begin a new live stream; returns (audio_id, push_queue).

        Producer puts chunks onto the queue, then None when done.
        The HTTP handler reads via iter_chunks(audio_id).
        """
        if not extension.startswith("."):
            extension = "." + extension
        audio_id = secrets.token_urlsafe(12)
        stream = _LiveStream(
            queue=asyncio.Queue(maxsize=128),
            extension=extension,
            mime=mime,
            started_at=time.time(),
        )
        with self._lock:
            self._streams[audio_id] = stream
            self._evict_streams()
        return audio_id, stream.queue

    def get_stream(self, audio_id: str) -> _LiveStream | None:
        with self._lock:
            return self._streams.get(audio_id)

    def path_for(self, audio_id: str) -> Path | None:
        with self._lock:
            return self._files.get(audio_id)

    async def iter_chunks(self, audio_id: str) -> AsyncIterator[bytes]:
        """Async iterator over a live stream's chunks.

        - Yields any already-buffered bytes (handles client connecting after
          the producer started pushing).
        - Then yields new chunks as they arrive until end-of-stream sentinel.
        - If the stream is already done, replays the buffered content.
        """
        stream = self.get_stream(audio_id)
        if stream is None:
            return

        already_buffered = bytes(stream.buffered)
        if already_buffered:
            yield already_buffered

        if stream.done:
            return

        while True:
            chunk = await stream.queue.get()
            if chunk is None:
                stream.done = True
                return
            stream.buffered.extend(chunk)
            yield chunk

    def _evict_files(self) -> None:
        while len(self._files) > self._max:
            _id, old_path = self._files.popitem(last=False)
            try:
                old_path.unlink(missing_ok=True)
            except OSError:
                pass

    def _evict_streams(self) -> None:
        while len(self._streams) > self._max:
            self._streams.popitem(last=False)
