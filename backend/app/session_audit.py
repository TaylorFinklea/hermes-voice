"""Extract tool-call summaries from Hermes sessions for client-side auditing.

After each turn we export the session via `hermes sessions export` and pull
out the tool calls + outcomes made during *this* turn (filtered by timestamp).
The iOS app renders these between the user/assistant bubbles so you can see
what Hermes actually did, without those rows being spoken aloud.

We extract a compact summary (name, preview, ok) rather than the full tool
result — a single `read_file` could be 100KB and we don't want to ship that
over the wire just for display.

Security: uses asyncio.create_subprocess_exec with an explicit argv list
(never shell=True), so session ids cannot inject shell metacharacters.
"""
from __future__ import annotations

import asyncio
import json
from dataclasses import dataclass

from .config import Settings


@dataclass(frozen=True)
class ToolCallSummary:
    name: str       # e.g. "terminal", "read_file"
    preview: str    # short human-readable arg summary
    ok: bool        # did it succeed?

    def as_dict(self) -> dict:
        return {"name": self.name, "preview": self.preview, "ok": self.ok}


async def _export_messages(settings: Settings, session_id: str) -> list[dict]:
    """Export a session to JSON and return its `messages` list ([] on failure)."""
    if not session_id:
        return []

    spawn = asyncio.create_subprocess_exec
    try:
        proc = await spawn(
            settings.hermes_bin, "sessions", "export",
            "--session-id", session_id, "-",
            stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
        stdout_b, _ = await asyncio.wait_for(proc.communicate(), timeout=10.0)
        if proc.returncode != 0:
            return []
    except (FileNotFoundError, asyncio.TimeoutError):
        return []

    raw = stdout_b.decode("utf-8", errors="replace").strip()
    if not raw:
        return []

    try:
        data = json.loads(raw.splitlines()[0])
    except (json.JSONDecodeError, IndexError):
        return []

    return data.get("messages", [])


async def fetch_tool_calls_since(
    settings: Settings, session_id: str, since_ts: float
) -> list[ToolCallSummary]:
    """Return tool calls made in the session after `since_ts` (unix seconds).

    Returns [] on any failure — auditing must never break a successful turn.
    """
    messages = await _export_messages(settings, session_id)
    return _summarize(messages, since_ts)


async def fetch_turn_result(
    settings: Settings, session_id: str, since_ts: float
) -> tuple[str, list[ToolCallSummary]]:
    """Export once; return (assistant reply text, tool summaries) for this turn.

    The streaming turn path takes the reply from the session export (structured
    and clean) instead of parsing the CLI's boxed non-quiet stdout.
    """
    messages = await _export_messages(settings, session_id)
    return _latest_assistant_text(messages, since_ts), _summarize(messages, since_ts)


def _latest_assistant_text(messages: list[dict], since_ts: float) -> str:
    """The last non-empty assistant message content at/after `since_ts`."""
    text = ""
    for msg in messages:
        if float(msg.get("timestamp") or 0) < since_ts:
            continue
        if msg.get("role") == "assistant":
            content = msg.get("content")
            if isinstance(content, str) and content.strip():
                text = content.strip()
    return text


def _summarize(messages: list[dict], since_ts: float) -> list[ToolCallSummary]:
    """Walk messages in order, pair tool calls with their results."""
    summaries: list[ToolCallSummary] = []
    # Map from tool_call_id → index into summaries, so the matching tool
    # result can update the `ok` field in place.
    pending: dict[str, int] = {}

    for msg in messages:
        ts = float(msg.get("timestamp") or 0)
        if ts < since_ts:
            continue

        role = msg.get("role")
        if role == "assistant":
            calls = msg.get("tool_calls") or []
            for tc in calls:
                fn = tc.get("function") or {}
                name = fn.get("name") or "tool"
                args_raw = fn.get("arguments") or ""
                summaries.append(ToolCallSummary(
                    name=name,
                    preview=_preview(name, args_raw),
                    ok=True,  # optimistic; updated when result arrives
                ))
                tcid = tc.get("id") or tc.get("call_id")
                if tcid:
                    pending[tcid] = len(summaries) - 1

        elif role == "tool":
            tcid = msg.get("tool_call_id")
            idx = pending.pop(tcid, None) if tcid else None
            if idx is None:
                continue
            ok = _result_ok(msg.get("content") or "")
            existing = summaries[idx]
            summaries[idx] = ToolCallSummary(
                name=existing.name, preview=existing.preview, ok=ok,
            )

    return summaries


def _preview(name: str, args_raw: str) -> str:
    """Per-tool short preview. Falls back to the first 80 chars of args."""
    try:
        args = json.loads(args_raw) if args_raw else {}
    except json.JSONDecodeError:
        args = {}

    if isinstance(args, dict):
        if name == "terminal" and "command" in args:
            return _truncate(str(args["command"]), 140)
        for key in ("path", "file_path", "filename", "url", "query", "text"):
            if key in args:
                return _truncate(f"{key}={args[key]!r}", 140)
        if args:
            first_key = next(iter(args))
            return _truncate(f"{first_key}={args[first_key]!r}", 140)

    return _truncate(args_raw, 140)


def _truncate(s: str, n: int) -> str:
    s = " ".join(s.split())
    return s if len(s) <= n else s[: n - 1] + "…"


def _result_ok(content: str) -> bool:
    """Best-effort: look for an exit_code or `error` key in the result JSON."""
    try:
        parsed = json.loads(content)
    except (json.JSONDecodeError, TypeError):
        return True
    if isinstance(parsed, dict):
        if "exit_code" in parsed:
            return parsed["exit_code"] == 0
        if parsed.get("error"):
            return False
    return True
