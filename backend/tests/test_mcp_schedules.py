"""Smoke tests for the stdio MCP server proxy.

We don't spin up the full MCP protocol here — that's an end-to-end concern
covered by `hermes mcp test`. These tests just verify the tool functions
proxy correctly to the REST API via httpx + handle disambiguation.
"""
from __future__ import annotations

from pathlib import Path

import pytest

from app import schedules
from app.mcp_schedules import create_schedule, delete_schedule, list_schedules
from tests.conftest import FakeHermes, FakeTTS, build_client


@pytest.fixture
def temp_db(tmp_path: Path, monkeypatch) -> Path:
    db = tmp_path / "schedules.db"
    monkeypatch.setattr(schedules, "DEFAULT_DB_PATH", db)
    return db


@pytest.fixture
def live_backend(temp_db: Path, monkeypatch):
    """Start the FastAPI app on a real loopback port so the MCP server can hit it."""
    import threading
    import time as _time

    import uvicorn
    from app.main import create_app

    app = create_app(hermes=FakeHermes(), tts=FakeTTS())
    # Port 0 → kernel assigns a free one.
    config = uvicorn.Config(app, host="127.0.0.1", port=0, log_level="warning")
    server = uvicorn.Server(config)
    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()

    # Spin until the server reports started + its actual port.
    for _ in range(50):
        if server.started and server.servers:
            break
        _time.sleep(0.05)

    port = server.servers[0].sockets[0].getsockname()[1]
    monkeypatch.setenv("HERMES_VOICE_BASE_URL", f"http://127.0.0.1:{port}")
    monkeypatch.delenv("HERMES_VOICE_TOKEN", raising=False)
    yield port

    server.should_exit = True
    thread.join(timeout=2)


@pytest.mark.asyncio
async def test_create_then_list_then_delete_by_id(live_backend) -> None:
    created = await create_schedule(
        cadence_seconds=120, prompt="weather", display_name="weather updates"
    )
    assert created["display_name"] == "weather updates"
    assert created["cadence_seconds"] == 120

    listed = await list_schedules()
    assert any(s["id"] == created["id"] for s in listed)

    result = await delete_schedule(id=created["id"])
    assert result == {"deleted": True, "id": created["id"], "display_name": None}

    after = await list_schedules()
    assert not any(s["id"] == created["id"] for s in after)


@pytest.mark.asyncio
async def test_delete_by_display_name_match(live_backend) -> None:
    a = await create_schedule(
        cadence_seconds=300, prompt="weather", display_name="weather updates"
    )
    b = await create_schedule(
        cadence_seconds=900, prompt="emails", display_name="email check"
    )

    # Substring match should find exactly one.
    result = await delete_schedule(display_name_match="weather")
    assert result["deleted"] is True
    assert result["id"] == a["id"]
    assert result["display_name"] == "weather updates"

    # The other one should still be there.
    listed = await list_schedules()
    ids = {s["id"] for s in listed}
    assert b["id"] in ids


@pytest.mark.asyncio
async def test_delete_no_match_returns_candidates(live_backend) -> None:
    await create_schedule(
        cadence_seconds=300, prompt="weather", display_name="weather updates"
    )
    result = await delete_schedule(display_name_match="bogus")
    assert result["error"] == "no matching schedule"
    assert "weather updates" in result["candidates"]


@pytest.mark.asyncio
async def test_delete_ambiguous_match_lists_options(live_backend) -> None:
    await create_schedule(
        cadence_seconds=300, prompt="morning weather", display_name="morning weather"
    )
    await create_schedule(
        cadence_seconds=300, prompt="evening weather", display_name="evening weather"
    )
    result = await delete_schedule(display_name_match="weather")
    assert result["error"] == "ambiguous match"
    assert set(result["candidates"]) == {"morning weather", "evening weather"}


@pytest.mark.asyncio
async def test_delete_requires_either_arg() -> None:
    result = await delete_schedule()
    assert "must provide" in result["error"]
