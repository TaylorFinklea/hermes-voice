"""Wrap the local `claude` CLI (Claude Code) as a HarnessClient.

Claude Code runs as a non-interactive, cwd-scoped coding agent inside the shared
harness workspace. Each iOS conversation maps to a Claude Code session_id, which
we capture from the stream's `system/init` event and pass back via `--resume`
on follow-up turns so the agent keeps its context.

Invocation (verified against claude v2.1.160):
    one-shot:   claude -p "<prompt>" --output-format json --permission-mode acceptEdits
    streaming:  claude -p "<prompt>" --output-format stream-json \
                    --include-partial-messages --verbose --permission-mode acceptEdits

NEVER run without `-p` — without it the CLI opens an interactive TTY and hangs a
headless run. `--permission-mode acceptEdits` auto-accepts file edits inside the
working directory without prompting, while still sandboxing other tools and
NEVER bypassing all permission checks (that would be `bypassPermissions`, which
we deliberately do not use).

Security: uses asyncio.create_subprocess_exec with an explicit argv list (never
shell=True), so user prompts cannot inject shell metacharacters.

Design: the event -> (StreamTool | StreamReply | None) parsing and the
turn-accumulation logic live in module-level pure functions (`parse_event`,
`StreamAccumulator`) that operate on already-decoded JSON dicts. `ask_streaming`
only spawns the process and decodes stdout lines; the pure functions are unit
tested with canned events and no subprocess.
"""
from __future__ import annotations

import asyncio
import json
import os
import shutil
from collections.abc import AsyncIterator
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

from ..config import Settings
from ..harness import HarnessSession
from ..hermes import HermesError, HermesReply, StreamReply, StreamTool
from ..session_audit import ToolCallSummary, _preview, _truncate

# Voice-shaping instruction for Claude, delivered as a per-invocation system
# prompt (CLI: --append-system-prompt; SDK: appended to the claude_code preset)
# on EVERY turn — fresh AND resumed. A user-message prelude only shaped the
# first turn, so an *attached* (resumed) session reverted to full markdown that
# TTS then read aloud; a system prompt is applied every turn and is the stronger
# instruction. It is a per-invocation flag, never written into the session
# transcript, so a later `claude --resume <id>` in a terminal is unaffected and
# behaves normally — voice shaping is scoped to harness-driven turns only.
_VOICE_SYSTEM_PROMPT = (
    "Your replies are delivered through a voice interface and read aloud by "
    "text-to-speech, then heard once — the user is listening, not reading. "
    "Always answer in plain spoken prose: never use markdown, headings, bullet "
    "or numbered lists, tables, code blocks, code fences, or asterisks. Never "
    "paste code, file contents, diffs, logs, or ASCII diagrams — describe the "
    "result in a sentence instead. Keep completed-action confirmations to one "
    "short sentence and informational answers to one or two sentences; expand "
    "only when explicitly asked. Do not narrate which tools you used, do not "
    "repeat the question back, and do not preamble with \"Sure\", \"I'll\", "
    "\"Let me\", or \"Here's\"."
)


# ---------------------------------------------------------------------------
# Pure parsing layer — operates on already-decoded JSON dicts, no subprocess.
# ---------------------------------------------------------------------------


@dataclass
class StreamAccumulator:
    """Accumulates a turn's session_id, live tool calls, and final text.

    Fed one decoded event dict at a time via `feed`, which returns a StreamTool
    to yield live (when a tool_use block first appears) or None. After the
    stream ends, `result(...)` builds the authoritative StreamReply.
    """

    session_id: str = ""
    text: str = ""
    tools: list[ToolCallSummary] = field(default_factory=list)
    # tool_use_id -> index into self.tools, so the matching tool_result can flip
    # the `ok` field in place.
    _pending: dict[str, int] = field(default_factory=dict)

    def feed(self, obj: dict) -> StreamTool | None:
        """Consume one event; return a StreamTool to emit live, else None."""
        etype = obj.get("type")

        # session_id rides on most events; the init event is authoritative but
        # we accept it from any event so a captured id is never lost.
        sid = obj.get("session_id")
        if sid and not self.session_id:
            self.session_id = sid

        if etype == "assistant":
            return self._feed_assistant(obj)
        if etype == "user":
            self._feed_user(obj)
            return None
        if etype == "result":
            # Terminal event: authoritative final text + session_id.
            if obj.get("session_id"):
                self.session_id = obj["session_id"]
            res = obj.get("result")
            if isinstance(res, str) and res.strip():
                self.text = res.strip()
            return None
        return None

    def _feed_assistant(self, obj: dict) -> StreamTool | None:
        msg = obj.get("message") or {}
        content = msg.get("content")
        if not isinstance(content, list):
            return None
        emit: StreamTool | None = None
        for blk in content:
            if not isinstance(blk, dict):
                continue
            btype = blk.get("type")
            if btype == "text":
                txt = blk.get("text")
                if isinstance(txt, str) and txt.strip():
                    self.text = txt.strip()
            elif btype == "tool_use":
                tool = _tool_from_use_block(blk)
                if tool is None:
                    continue
                stream_tool, tcid = tool
                self.tools.append(
                    ToolCallSummary(
                        name=stream_tool.name, preview=stream_tool.preview, ok=True
                    )
                )
                if tcid:
                    self._pending[tcid] = len(self.tools) - 1
                # Only emit one live preview per event (one yield point); the
                # rest are still recorded in self.tools.
                if emit is None:
                    emit = stream_tool
        return emit

    def _feed_user(self, obj: dict) -> None:
        msg = obj.get("message") or {}
        content = msg.get("content")
        if not isinstance(content, list):
            return
        for blk in content:
            if not isinstance(blk, dict) or blk.get("type") != "tool_result":
                continue
            tcid = blk.get("tool_use_id")
            idx = self._pending.pop(tcid, None) if tcid else None
            if idx is None:
                continue
            ok = not bool(blk.get("is_error", False))
            existing = self.tools[idx]
            self.tools[idx] = ToolCallSummary(
                name=existing.name, preview=existing.preview, ok=ok
            )

    def result(self) -> StreamReply:
        return StreamReply(
            text=self.text, session_id=self.session_id, tools=list(self.tools)
        )


def _tool_from_use_block(blk: dict) -> tuple[StreamTool, str | None] | None:
    """Build a StreamTool + its tool_use_id from a tool_use content block."""
    name = blk.get("name") or "tool"
    raw_input = blk.get("input")
    # session_audit._preview expects a JSON string of args; the CLI gives a dict.
    try:
        args_json = json.dumps(raw_input) if raw_input is not None else ""
    except (TypeError, ValueError):
        args_json = ""
    preview = _preview(name, args_json)
    return StreamTool(name=name, preview=preview), blk.get("id")


def parse_event(obj: dict) -> StreamTool | None:
    """Stateless convenience: extract the first live StreamTool from one event.

    Used by tests and any caller that only needs the per-event tool preview;
    accumulation across a turn goes through StreamAccumulator.
    """
    return StreamAccumulator().feed(obj)


# ---------------------------------------------------------------------------
# Session discovery — Claude stores each session as a JSONL transcript at
# ~/.claude/projects/<slugified-cwd>/<session_id>.jsonl. No CLI lists sessions,
# so we scan that tree. Resume is cwd-scoped, so the cwd captured here is what a
# resumed turn must run in. Functions take an optional projects_dir for testing.
# ---------------------------------------------------------------------------


def _claude_projects_dir() -> Path:
    return Path.home() / ".claude" / "projects"


def _parse_iso(value: object) -> float:
    """ISO-8601 (e.g. '2026-05-29T10:45:26.868Z') -> epoch float; 0.0 on fail."""
    if not isinstance(value, str) or not value:
        return 0.0
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return 0.0


def _first_user_text(obj: dict) -> str:
    """Best-effort user prompt text from a transcript event (for the preview)."""
    if isinstance(obj.get("content"), str):  # queue-operation enqueue event
        return obj["content"]
    if obj.get("type") == "user":
        content = (obj.get("message") or {}).get("content")
        if isinstance(content, str):
            return content
        if isinstance(content, list):
            parts = [
                b.get("text", "")
                for b in content
                if isinstance(b, dict) and b.get("type") == "text"
            ]
            return " ".join(p for p in parts if p)
    return ""


def _count_tool_uses(obj: dict) -> int:
    if obj.get("type") != "assistant":
        return 0
    content = (obj.get("message") or {}).get("content")
    if not isinstance(content, list):
        return 0
    return sum(
        1 for b in content if isinstance(b, dict) and b.get("type") == "tool_use"
    )


def session_meta_from_file(path: Path) -> HarnessSession | None:
    """Build a HarnessSession from one Claude `<session_id>.jsonl` transcript."""
    session_id = path.stem
    if not session_id:
        return None
    cwd: str | None = None
    preview = ""
    title: str | None = None
    last_ts = 0.0
    msg_count = 0
    tool_count = 0
    try:
        with path.open("r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(obj, dict):
                    continue
                if cwd is None and isinstance(obj.get("cwd"), str):
                    cwd = obj["cwd"]
                ts = _parse_iso(obj.get("timestamp"))
                if ts > last_ts:
                    last_ts = ts
                etype = obj.get("type")
                if etype == "ai-title" and isinstance(obj.get("aiTitle"), str):
                    title = obj["aiTitle"].strip() or title
                if etype in ("user", "assistant"):
                    msg_count += 1
                tool_count += _count_tool_uses(obj)
                if not preview:
                    preview = _first_user_text(obj)
    except OSError:
        return None
    try:
        st = path.stat()
    except OSError:
        st = None
    started_at = last_ts if last_ts > 0 else (st.st_mtime if st else 0.0)
    return HarnessSession(
        session_id=session_id,
        source="claude",
        started_at=started_at,
        message_count=msg_count,
        tool_call_count=tool_count,
        preview=_truncate(preview, 200),
        cwd=cwd,
        title=title,
        size_bytes=st.st_size if st else 0,
    )


def list_claude_sessions(
    limit: int = 30,
    projects_dir: Path | None = None,
    exclude: tuple[str, ...] = ("ClaudeProbe",),
) -> list[HarnessSession]:
    """Most-recent Claude sessions (by transcript mtime), newest first.

    Sessions whose project directory (the slugified cwd) contains any `exclude`
    substring are skipped — e.g. throwaway "ClaudeProbe" usage-probe sessions.
    The filter runs BEFORE the limit so the probes can't crowd real sessions out
    of the top N. `glob("*/*.jsonl")` is one level deep, so nested subagent
    transcripts are excluded too.
    """
    base = projects_dir or _claude_projects_dir()
    if not base.is_dir():
        return []
    try:
        files = [
            p
            for p in base.glob("*/*.jsonl")
            if not any(ex and ex in p.parent.name for ex in exclude)
        ]
        files.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    except OSError:
        return []
    out: list[HarnessSession] = []
    for path in files[: max(0, limit)]:
        meta = session_meta_from_file(path)
        if meta is not None:
            out.append(meta)
    return out


def session_cwd_from_disk(
    session_id: str, projects_dir: Path | None = None
) -> str | None:
    """The original working directory of a Claude session id, or None."""
    if not session_id:
        return None
    base = projects_dir or _claude_projects_dir()
    if not base.is_dir():
        return None
    for path in base.glob(f"*/{session_id}.jsonl"):
        try:
            with path.open("r", encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        obj = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if isinstance(obj, dict) and isinstance(obj.get("cwd"), str):
                        return obj["cwd"]
        except OSError:
            continue
    return None


# ---------------------------------------------------------------------------
# Adapter
# ---------------------------------------------------------------------------


class ClaudeAdapter:
    """Drives `claude -p` for one-shot and streaming voice turns."""

    bin = "claude"

    def __init__(self, settings: Settings):
        self._settings = settings

    def is_available(self) -> bool:
        return shutil.which(self.bin) is not None

    def describe(self) -> dict:
        return {
            "bin": self.bin,
            "available": self.is_available(),
            "timeout_seconds": self._settings.hermes_timeout,
            "workspace_dir": self._settings.harness_workspace_dir,
            "sandbox": self._settings.harness_sandbox,
            "permission_mode": "acceptEdits",
        }

    def _workspace(self) -> str:
        wd = self._settings.harness_workspace_dir
        os.makedirs(wd, exist_ok=True)
        return wd

    def _session_cwd(self, session_id: str | None) -> str | None:
        if not session_id:
            return None
        return session_cwd_from_disk(session_id)

    def _resolve_cwd(self, session_id: str | None) -> tuple[str, bool]:
        """(cwd, is_external) for a turn. External = resuming a session whose
        real working directory is a repo OUTSIDE our shared workspace; those
        turns run read-only (see _base_args) so voice can't edit real code until
        the approval layer lands."""
        ext = self._session_cwd(session_id)
        if ext and ext != self._settings.harness_workspace_dir:
            return ext, True
        return self._workspace(), False

    def _base_args(
        self, prompt: str, session_id: str | None, read_only: bool
    ) -> list[str]:
        args = [self.bin, "-p", prompt]
        # Voice-shape EVERY turn (fresh and resumed) via a per-invocation system
        # prompt; --append-system-prompt composes with -p, --resume, and either
        # --permission-mode and is never stored in the session transcript.
        args += ["--append-system-prompt", _VOICE_SYSTEM_PROMPT]
        if read_only:
            # Attached to a real repo: read/analyze only — no edits or mutating
            # commands. Write-by-voice arrives with the approval layer (Phase B).
            args += ["--permission-mode", "plan", "--allowedTools", "Read,Bash(git *)"]
        else:
            args += ["--permission-mode", "acceptEdits"]
        if session_id:
            args.extend(["--resume", session_id])
        return args

    async def list_sessions(self, limit: int = 30) -> list[HarnessSession]:
        """Recent Claude Code sessions for the iOS attach picker (probe sessions
        filtered per settings.claude_session_exclude)."""
        exclude = tuple(self._settings.claude_session_exclude)
        return await asyncio.to_thread(list_claude_sessions, limit, None, exclude)

    async def ask(self, prompt: str, session_id: str | None = None) -> HermesReply:
        if not prompt.strip():
            raise HermesError("empty prompt")

        cwd, read_only = self._resolve_cwd(session_id)
        args = self._base_args(prompt, session_id, read_only)
        args.extend(["--output-format", "json"])

        try:
            proc = await asyncio.create_subprocess_exec(
                *args,
                cwd=cwd,
                stdin=asyncio.subprocess.DEVNULL,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
        except FileNotFoundError as e:
            raise HermesError(f"claude binary not found: {self.bin}") from e

        try:
            stdout_b, stderr_b = await asyncio.wait_for(
                proc.communicate(), timeout=self._settings.hermes_timeout
            )
        except asyncio.TimeoutError as e:
            proc.kill()
            raise HermesError(
                f"claude timed out after {self._settings.hermes_timeout}s"
            ) from e

        stdout = stdout_b.decode("utf-8", errors="replace")
        stderr = stderr_b.decode("utf-8", errors="replace")

        if proc.returncode != 0:
            tail = (stderr or stdout).strip().splitlines()[-5:]
            raise HermesError(
                f"claude exited {proc.returncode}: " + " | ".join(tail)
            )

        return _parse_oneshot(stdout)

    async def ask_streaming(
        self, prompt: str, session_id: str | None = None
    ) -> AsyncIterator[StreamTool | StreamReply]:
        if not prompt.strip():
            raise HermesError("empty prompt")

        cwd, read_only = self._resolve_cwd(session_id)
        args = self._base_args(prompt, session_id, read_only)
        args.extend(
            [
                "--output-format",
                "stream-json",
                "--include-partial-messages",
                "--verbose",
            ]
        )

        try:
            proc = await asyncio.create_subprocess_exec(
                *args,
                cwd=cwd,
                stdin=asyncio.subprocess.DEVNULL,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL,
            )
        except FileNotFoundError as e:
            raise HermesError(f"claude binary not found: {self.bin}") from e

        acc = StreamAccumulator(session_id=session_id or "")
        stdout = proc.stdout
        assert stdout is not None
        try:
            async with asyncio.timeout(self._settings.hermes_timeout):
                async for raw in stdout:
                    line = raw.decode("utf-8", errors="replace").strip()
                    if not line:
                        continue
                    try:
                        obj = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if not isinstance(obj, dict):
                        continue
                    tool = acc.feed(obj)
                    if tool is not None:
                        yield tool
        except TimeoutError as e:
            proc.kill()
            await proc.wait()
            raise HermesError(
                f"claude timed out after {self._settings.hermes_timeout}s"
            ) from e
        await proc.wait()

        reply = acc.result()
        if not reply.text:
            raise HermesError("claude returned no assistant text")
        yield reply


def _parse_oneshot(stdout: str) -> HermesReply:
    """Parse the single-line `--output-format json` result object."""
    raw = stdout.strip()
    if not raw:
        raise HermesError("claude returned no output")
    # The result object is the last JSON line (warnings may precede it).
    obj: dict | None = None
    for line in reversed(raw.splitlines()):
        line = line.strip()
        if not line:
            continue
        try:
            candidate = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(candidate, dict):
            obj = candidate
            break
    if obj is None:
        raise HermesError("claude returned no parseable JSON result")

    if obj.get("is_error"):
        raise HermesError(f"claude reported an error: {obj.get('result')!r}")

    text = obj.get("result")
    if not isinstance(text, str) or not text.strip():
        raise HermesError("claude returned no assistant text")

    return HermesReply(text=text.strip(), session_id=obj.get("session_id") or "")
