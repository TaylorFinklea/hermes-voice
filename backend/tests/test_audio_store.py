"""AudioStore lifecycle: producer cancellation, TTL sweep, shutdown cleanup."""
import asyncio
import os

from app.audio_store import AudioStore, _TTL_SECONDS


def test_close_removes_temp_dir_and_cancels_producers():
    async def scenario():
        store = AudioStore()
        root = store.root
        assert root.is_dir()

        audio_id, _queue = store.start_stream(".mp3", "audio/mpeg")

        async def never_ends():
            await asyncio.Event().wait()

        task = asyncio.create_task(never_ends())
        store.set_producer(audio_id, task)

        store.close()
        await asyncio.sleep(0)  # let the cancellation propagate
        assert task.cancelled()
        assert not root.exists()

    asyncio.run(scenario())


def test_set_producer_on_evicted_stream_cancels_task():
    async def scenario():
        store = AudioStore()

        async def never_ends():
            await asyncio.Event().wait()

        task = asyncio.create_task(never_ends())
        # No stream with this id exists → the task must not be left orphaned.
        store.set_producer("does-not-exist", task)
        await asyncio.sleep(0)
        assert task.cancelled()
        store.close()

    asyncio.run(scenario())


def test_sweep_drops_files_past_ttl():
    store = AudioStore()
    old_id = store.put(b"old", "mp3")
    old_path = store.path_for(old_id)
    assert old_path is not None
    # Backdate the file well past the TTL, then a new put() triggers the sweep.
    past = (os.path.getmtime(old_path)) - (_TTL_SECONDS + 60)
    os.utime(old_path, (past, past))

    store.put(b"new", "mp3")  # opportunistic sweep runs here

    assert store.path_for(old_id) is None
    assert not old_path.exists()
    store.close()


def test_sweep_drops_streams_past_ttl():
    async def scenario():
        store = AudioStore()
        old_id, _q = store.start_stream(".mp3", "audio/mpeg")

        async def never_ends():
            await asyncio.Event().wait()

        task = asyncio.create_task(never_ends())
        store.set_producer(old_id, task)
        # Backdate the stream past the TTL; a new start_stream triggers the sweep.
        store._stream_times[old_id] -= _TTL_SECONDS + 60

        store.start_stream(".mp3", "audio/mpeg")
        await asyncio.sleep(0)

        assert store.get_stream(old_id) is None
        assert task.cancelled()
        store.close()

    asyncio.run(scenario())
