"""Phase B approval/question broker + the answer endpoint."""
import asyncio

import pytest

from app.approvals import ApprovalBroker
from tests.conftest import FakeHermes, build_client


def test_broker_request_resolved_by_answer():
    async def scenario():
        broker = ApprovalBroker()
        tid = broker.open()
        # A turn asks for approval; this awaits the client's answer.
        task = asyncio.create_task(
            broker.request(tid, {"type": "approval_request", "tool": "Edit"})
        )
        # The request surfaces as a queued event for the SSE stream, with an id.
        events = broker.events(tid)
        event = await asyncio.wait_for(events.__anext__(), 1.0)
        assert event["type"] == "approval_request"
        assert event["tool"] == "Edit"
        rid = event["request_id"]
        # The client answers -> the awaiting request() returns that value.
        assert broker.answer(tid, rid, "deny") is True
        assert await asyncio.wait_for(task, 1.0) == "deny"
        broker.close(tid)

    asyncio.run(scenario())


def test_broker_answer_unknown_is_false():
    broker = ApprovalBroker()
    assert broker.answer("nope", "nope", "allow") is False
    tid = broker.open()
    assert broker.answer(tid, "nope", "allow") is False  # open turn, unknown req


def test_broker_close_cancels_pending():
    async def scenario():
        broker = ApprovalBroker()
        tid = broker.open()
        task = asyncio.create_task(
            broker.request(tid, {"type": "approval_request"})
        )
        # Drain the event so request() is parked on its future, then close.
        events = broker.events(tid)
        await asyncio.wait_for(events.__anext__(), 1.0)
        broker.close(tid)
        with pytest.raises(asyncio.CancelledError):
            await asyncio.wait_for(task, 1.0)

    asyncio.run(scenario())


def test_answer_endpoint_unknown_turn_404():
    client = build_client(hermes=FakeHermes(), stt=None, tts=None)
    resp = client.post(
        "/api/turns/nope/answer", json={"request_id": "x", "value": "allow"}
    )
    assert resp.status_code == 404
