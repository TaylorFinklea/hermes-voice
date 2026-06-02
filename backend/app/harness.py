"""Harness abstraction — the backend can front any CLI coding agent.

A `HarnessClient` drives one agent (Hermes, Claude Code, Codex, OpenCode) behind
a uniform contract, so the FastAPI layer stays agent-agnostic and a turn can be
routed to a different agent per request (the `harness` field, mirroring `tts`).

The concrete Hermes implementation lives in `hermes.py` (`HermesClient`); other
adapters live in their own modules and are registered in `main.create_app`. This
is a structural Protocol — adapters satisfy it by shape, not inheritance, so the
existing `HermesClient` / `MockHermesClient` / test `FakeHermes` already conform.
"""
from __future__ import annotations

from collections.abc import AsyncIterator
from dataclasses import dataclass
from typing import Protocol, runtime_checkable

from .hermes import HermesReply, StreamReply, StreamTool


@dataclass(frozen=True)
class HarnessSession:
    """One past session a harness surfaces for the 'attach' picker.

    `cwd`/`title` are populated by coding agents (e.g. Claude Code, whose
    sessions are working-directory-scoped); Hermes leaves them None. Returned by
    an adapter's OPTIONAL `list_sessions(limit)` method — the
    /api/harnesses/{id}/sessions endpoint fetches it via getattr (mirroring how
    /api/voices fetches a TTS provider's optional `list_voices`), so an adapter
    without it simply lists nothing.
    """

    session_id: str
    source: str            # harness id, e.g. "claude"
    started_at: float      # unix ts (last activity) — for sort + display
    message_count: int
    tool_call_count: int
    preview: str
    cwd: str | None = None
    title: str | None = None


@runtime_checkable
class HarnessClient(Protocol):
    """The contract every harness adapter satisfies."""

    def is_available(self) -> bool:
        """True when the underlying CLI is installed and usable."""
        ...

    def describe(self) -> dict:
        """Diagnostic info for /health and /api/harnesses."""
        ...

    async def ask(
        self, prompt: str, session_id: str | None = None
    ) -> HermesReply:
        """One-shot turn → (assistant text, session_id)."""
        ...

    def ask_streaming(
        self, prompt: str, session_id: str | None = None
    ) -> AsyncIterator[StreamTool | StreamReply]:
        """Live tool previews, then a final authoritative StreamReply."""
        ...


# Display names for the harnesses the app knows about. Unknown ids fall back to
# a title-cased id in the /api/harnesses response.
HARNESS_DISPLAY_NAMES: dict[str, str] = {
    "hermes": "Hermes",
    "claude": "Claude Code",
    "codex": "Codex",
    "opencode": "OpenCode",
}
