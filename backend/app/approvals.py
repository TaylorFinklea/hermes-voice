"""Bidirectional approval / question channel for voice-mediated tool approval.

Phase B. A streaming turn can pause to ASK the client something — an approval
("Claude wants to edit foo.py — yes/no") or a structured question (a single- or
multi-select). The request is emitted as an SSE event on the turn's stream; the
client answers via `POST /api/turns/{turn_id}/answer`, which resolves the
awaiting Future so the agent's permission callback (or the AskUser tool) can
return its decision and the turn continues.

This module is the SDK-agnostic core: a per-turn registry of pending Futures and
an emit queue. The Claude-SDK `can_use_tool` callback and the AskUser MCP tool
(later slices) call `request(...)`; the SSE generator drains `events(...)`; the
answer endpoint calls `answer(...)`.
"""
from __future__ import annotations

import asyncio
import uuid
from dataclasses import dataclass, field
from typing import Any

# Sentinel pushed on the queue to end a turn's event drain cleanly.
_CLOSE = object()


@dataclass
class _Turn:
    queue: asyncio.Queue = field(default_factory=asyncio.Queue)
    pending: dict[str, asyncio.Future] = field(default_factory=dict)


class ApprovalBroker:
    """Per-turn registry of pending approval/question futures + an emit queue.

    One broker instance lives on `app.state.approvals`. A turn opens a channel,
    `request(...)`s zero or more decisions while it runs, then `close(...)`s.
    """

    def __init__(self) -> None:
        self._turns: dict[str, _Turn] = {}

    def open(self) -> str:
        """Start a channel for a new turn; returns the turn_id sent to the client."""
        turn_id = uuid.uuid4().hex
        self._turns[turn_id] = _Turn()
        return turn_id

    def close(self, turn_id: str) -> None:
        """End a turn: cancel any still-pending futures and stop the drain."""
        turn = self._turns.pop(turn_id, None)
        if turn is None:
            return
        for fut in turn.pending.values():
            if not fut.done():
                fut.cancel()
        turn.queue.put_nowait(_CLOSE)

    async def request(self, turn_id: str, payload: dict) -> Any:
        """Emit an approval/question event and await the client's answer.

        `payload` is the event body (e.g. {"type": "approval_request", "tool":
        "Edit", "title": "...", "preview": "..."}); a `request_id` is added. The
        returned value is whatever the answer endpoint supplied (e.g. "allow" /
        "deny", or a list of selected options). Raises KeyError if the turn isn't
        open, CancelledError if the turn closes before an answer arrives.
        """
        turn = self._turns.get(turn_id)
        if turn is None:
            raise KeyError(turn_id)
        request_id = uuid.uuid4().hex
        fut: asyncio.Future = asyncio.get_running_loop().create_future()
        turn.pending[request_id] = fut
        await turn.queue.put({**payload, "request_id": request_id})
        try:
            return await fut
        finally:
            turn.pending.pop(request_id, None)

    def emit(self, turn_id: str, event: dict) -> None:
        """Push an agent message event onto the turn's stream (no answer awaited).

        Used by the SDK turn driver to interleave assistant text / tool-call /
        done events with the approval/question requests on a single queue, so the
        SSE generator can drain one channel.
        """
        turn = self._turns.get(turn_id)
        if turn is not None:
            turn.queue.put_nowait(event)

    def answer(self, turn_id: str, request_id: str, value: Any) -> bool:
        """Resolve a pending request with the client's answer. False if unknown."""
        turn = self._turns.get(turn_id)
        if turn is None:
            return False
        fut = turn.pending.get(request_id)
        if fut is None or fut.done():
            return False
        fut.set_result(value)
        return True

    async def events(self, turn_id: str):
        """Async-iterate the turn's queued request events until it closes.

        The SSE generator merges this with the agent's message events so the
        client sees approval/question prompts inline in the turn stream.
        """
        turn = self._turns.get(turn_id)
        if turn is None:
            return
        while True:
            item = await turn.queue.get()
            if item is _CLOSE:
                return
            yield item
