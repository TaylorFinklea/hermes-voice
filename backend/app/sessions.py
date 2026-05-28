"""Read-only access to Hermes' session SQLite store.

Hermes writes session/message data to ~/.hermes/state.db. We open it read-only
so we never risk corrupting Hermes' state, and run queries via asyncio.to_thread
to keep the event loop free.

Cleans the voice prelude out of user-message previews so the history list shows
what the user actually said, not the "You are answering through a voice
interface..." prefix.
"""
from __future__ import annotations

import asyncio
import json
import sqlite3
from dataclasses import dataclass
from pathlib import Path

DEFAULT_DB_PATH = Path.home() / ".hermes" / "state.db"


@dataclass
class SessionSummary:
    id: str
    source: str
    started_at: float
    message_count: int
    tool_call_count: int
    preview: str  # user-friendly first message, with voice prelude stripped


@dataclass
class SessionMessage:
    role: str           # user / assistant / tool
    content: str
    timestamp: float
    tool_name: str | None
    tool_calls: list[dict] | None  # for assistant messages with tool calls


@dataclass
class SessionDetail:
    id: str
    source: str
    started_at: float
    title: str | None
    messages: list[SessionMessage]


def _connect(path: Path) -> sqlite3.Connection:
    # Open read-only via URI; we should never write to Hermes' DB.
    uri = f"file:{path}?mode=ro"
    conn = sqlite3.connect(uri, uri=True, timeout=2.0)
    conn.row_factory = sqlite3.Row
    return conn


def _strip_voice_prelude(content: str) -> str:
    """Best-effort: remove our voice prelude prefix from a user message.

    The prelude ends with "Just answer." followed by "\\n\\n<actual prompt>".
    If the message contains that boundary, return what follows. Otherwise
    return the original content.
    """
    marker = "Just answer."
    if marker in content:
        after = content.split(marker, 1)[1].lstrip()
        if after:
            return after
    return content


async def list_sessions(
    limit: int = 20,
    source: str | None = None,
    db_path: Path = DEFAULT_DB_PATH,
) -> list[SessionSummary]:
    return await asyncio.to_thread(_list_sync, limit, source, db_path)


def _list_sync(limit: int, source: str | None, db_path: Path) -> list[SessionSummary]:
    if not db_path.exists():
        return []

    query = """
        SELECT
            s.id, s.source, s.started_at,
            COALESCE(s.message_count, 0) AS message_count,
            COALESCE(s.tool_call_count, 0) AS tool_call_count,
            (
                SELECT content FROM messages
                WHERE session_id = s.id AND role = 'user' AND content IS NOT NULL
                ORDER BY timestamp ASC LIMIT 1
            ) AS first_user_content
        FROM sessions s
    """
    params: list = []
    if source:
        query += " WHERE s.source = ?"
        params.append(source)
    query += " ORDER BY s.started_at DESC LIMIT ?"
    params.append(limit)

    with _connect(db_path) as conn:
        rows = conn.execute(query, params).fetchall()

    results: list[SessionSummary] = []
    for r in rows:
        raw = r["first_user_content"] or ""
        preview = _strip_voice_prelude(raw)
        # If the preview is empty (no user message yet, or prelude-only),
        # fall back to a short marker so the UI has something to show.
        if not preview.strip():
            preview = "(no content)"
        # Hard cap so a runaway message doesn't blow up the list payload.
        if len(preview) > 200:
            preview = preview[:197] + "..."
        results.append(SessionSummary(
            id=r["id"],
            source=r["source"],
            started_at=float(r["started_at"]),
            message_count=int(r["message_count"]),
            tool_call_count=int(r["tool_call_count"]),
            preview=preview,
        ))
    return results


async def get_session(
    session_id: str, db_path: Path = DEFAULT_DB_PATH
) -> SessionDetail | None:
    return await asyncio.to_thread(_get_sync, session_id, db_path)


def _get_sync(session_id: str, db_path: Path) -> SessionDetail | None:
    if not db_path.exists():
        return None

    with _connect(db_path) as conn:
        session_row = conn.execute(
            "SELECT id, source, started_at, title FROM sessions WHERE id = ?",
            (session_id,),
        ).fetchone()
        if session_row is None:
            return None

        message_rows = conn.execute(
            """
            SELECT role, content, timestamp, tool_name, tool_calls
            FROM messages
            WHERE session_id = ?
            ORDER BY timestamp ASC, id ASC
            """,
            (session_id,),
        ).fetchall()

    messages: list[SessionMessage] = []
    for m in message_rows:
        role = m["role"]
        raw_content = m["content"] or ""
        # Only strip prelude from the FIRST user message (the only place it
        # would appear, since we skip the prelude on resume turns).
        if role == "user" and not messages:
            content = _strip_voice_prelude(raw_content)
        else:
            content = raw_content

        tool_calls = None
        tcs_raw = m["tool_calls"]
        if tcs_raw:
            try:
                tool_calls = json.loads(tcs_raw)
            except json.JSONDecodeError:
                tool_calls = None

        messages.append(SessionMessage(
            role=role,
            content=content,
            timestamp=float(m["timestamp"]),
            tool_name=m["tool_name"],
            tool_calls=tool_calls,
        ))

    return SessionDetail(
        id=session_row["id"],
        source=session_row["source"],
        started_at=float(session_row["started_at"]),
        title=session_row["title"],
        messages=messages,
    )
