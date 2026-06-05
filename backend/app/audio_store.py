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
import logging
import secrets
import shutil
import threading
import time
from collections import OrderedDict
from collections.abc import AsyncIterator
from dataclasses import dataclass, field
from pathlib import Path
from tempfile import mkdtemp

logger = logging.getLogger(__name__)

# How long a completed file / finished stream lingers before the opportunistic
# sweep drops it. Long enough to cover a backgrounded app resuming a replay,
# short enough that a long-lived process doesn't accrete disk unbounded.
_TTL_SECONDS = 1800.0


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
    # The background TTS producer feeding this stream — held so eviction / TTL /
    # shutdown can cancel it, instead of leaving it blocked on a full queue with
    # no consumer (which would pin the upstream TTS connection open forever).
    producer: asyncio.Task | None = None


class AudioStore:
    def __init__(self, max_items: int = 64):
        self._dir = Path(mkdtemp(prefix="harness-voice-"))
        self._max = max_items
        self._files: OrderedDict[str, Path] = OrderedDict()
        self._stream_times: dict[str, float] = {}
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
            self._sweep_locked()
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
        now = time.time()
        stream = _LiveStream(
            queue=asyncio.Queue(maxsize=128),
            extension=extension,
            mime=mime,
            started_at=now,
        )
        with self._lock:
            self._sweep_locked()
            self._streams[audio_id] = stream
            self._stream_times[audio_id] = now
            self._evict_streams()
        return audio_id, stream.queue

    def set_producer(self, audio_id: str, task: asyncio.Task) -> None:
        """Attach the background TTS producer task to a live stream so the store
        can cancel it on eviction / TTL / shutdown. If the stream is already
        gone (evicted), cancel the task immediately rather than orphan it."""
        with self._lock:
            stream = self._streams.get(audio_id)
            if stream is None:
                task.cancel()
                return
            stream.producer = task

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

    def close(self) -> None:
        """Cancel every live producer and delete the temp dir. Call on shutdown
        so a restart doesn't leak a `harness-voice-*` dir each time."""
        with self._lock:
            for stream in self._streams.values():
                if stream.producer is not None:
                    stream.producer.cancel()
            self._streams.clear()
            self._stream_times.clear()
            self._files.clear()
        shutil.rmtree(self._dir, ignore_errors=True)

    def _evict_files(self) -> None:
        while len(self._files) > self._max:
            _id, old_path = self._files.popitem(last=False)
            try:
                old_path.unlink(missing_ok=True)
            except OSError:
                pass

    def _evict_streams(self) -> None:
        while len(self._streams) > self._max:
            audio_id, stream = self._streams.popitem(last=False)
            self._stream_times.pop(audio_id, None)
            if stream.producer is not None:
                stream.producer.cancel()

    def _sweep_locked(self, now: float | None = None) -> None:
        """Drop files + streams past their TTL. Caller must hold `self._lock`.
        Bounds disk/connection use in a long-lived process between evictions."""
        cutoff = (now if now is not None else time.time()) - _TTL_SECONDS
        for audio_id in [a for a, t in self._stream_times.items() if t < cutoff]:
            stream = self._streams.pop(audio_id, None)
            self._stream_times.pop(audio_id, None)
            if stream is not None and stream.producer is not None:
                stream.producer.cancel()
        stale_files = [
            audio_id
            for audio_id, path in self._files.items()
            if _mtime(path) < cutoff
        ]
        for audio_id in stale_files:
            path = self._files.pop(audio_id, None)
            if path is not None:
                try:
                    path.unlink(missing_ok=True)
                except OSError:
                    pass


def _mtime(path: Path) -> float:
    try:
        return path.stat().st_mtime
    except OSError:
        return 0.0
