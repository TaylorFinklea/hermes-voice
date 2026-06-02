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

from ..config import Settings
from ..hermes import HermesError, HermesReply, StreamReply, StreamTool
from ..session_audit import ToolCallSummary, _preview

# Same voice-shaping prelude philosophy as Hermes, but kept local so the Claude
# adapter can be tuned independently. Prepended only on the FIRST turn; on
# --resume turns the session already carries it.
_VOICE_PRELUDE = (
    "You are answering through a voice interface; your reply is read aloud "
    "by text-to-speech and heard once. Write in plain spoken prose — no "
    "markdown, no bullet lists, no code blocks, no headings, no asterisks. "
    "Do not narrate which tools you used; only confirm the result. Keep "
    "completed-action replies to one short sentence; answer informational "
    "questions in one or two sentences. Do not repeat the question back and "
    "do not preamble with \"Sure\", \"I'll\", \"Let me\", or \"Here's\"."
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

    def _base_args(self, prompt: str, session_id: str | None) -> list[str]:
        shaped = prompt
        if _VOICE_PRELUDE and not session_id:
            shaped = f"{_VOICE_PRELUDE}\n\n{prompt}"
        args = [self.bin, "-p", shaped, "--permission-mode", "acceptEdits"]
        if session_id:
            args.extend(["--resume", session_id])
        return args

    async def ask(self, prompt: str, session_id: str | None = None) -> HermesReply:
        if not prompt.strip():
            raise HermesError("empty prompt")

        cwd = self._workspace()
        args = self._base_args(prompt, session_id)
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

        cwd = self._workspace()
        args = self._base_args(prompt, session_id)
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
