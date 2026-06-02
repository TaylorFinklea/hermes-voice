"""Wrap the OpenAI `codex` CLI (codex-cli 0.136.0) as a HarnessClient.

Codex runs non-interactively via `codex exec "<prompt>" --json`, emitting a
JSONL event stream on stdout. Each conversation maps to a Codex *thread* whose
id we capture from the first `thread.started` event and replay on follow-ups via
`codex exec resume <thread_id> "<prompt>" --json`, so the agent keeps its tool /
context memory across the voice exchange.

Verified event shapes (codex-cli 0.136.0, real capture):
    {"type":"thread.started","thread_id":"019e...-..."}
    {"type":"turn.started"}
    {"type":"item.started","item":{"id":"item_0","type":"command_execution",
        "command":"/bin/zsh -lc 'echo hi'","exit_code":null,"status":"in_progress"}}
    {"type":"item.completed","item":{"id":"item_0","type":"command_execution",
        "command":"...","aggregated_output":"hi\n","exit_code":0,"status":"completed"}}
    {"type":"item.started","item":{"id":"item_3","type":"file_change",
        "changes":[{"path":"/.../hello.txt","kind":"add"}],"status":"in_progress"}}
    {"type":"item.completed","item":{"id":"item_4","type":"agent_message","text":"done"}}
    {"type":"turn.completed","usage":{...}}

session_id source: the `thread_id` field of the `thread.started` event.

Sandbox / non-interactive: we run with `-c sandbox_mode="workspace-write"` (edits
allowed only inside the workspace, shell commands sandboxed) and
`-c approval_policy="never"` (no interactive approval prompts that would hang a
headless run). These are passed as config overrides rather than the `--sandbox` /
`-a` flags because `codex exec resume` does NOT accept those flags, but it does
accept `-c`. We never use `--dangerously-bypass-approvals-and-sandbox`.

Security: asyncio.create_subprocess_exec with an explicit argv list (never
shell=True), so prompts/session ids cannot inject shell metacharacters.
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

_BIN = "codex"

# Prepended to the FIRST turn of every voice-originated conversation (mirrors
# hermes._VOICE_PRELUDE): shapes the reply for TTS playback. Skipped on resume
# turns since Codex carries it via thread context.
_VOICE_PRELUDE = (
    "You are answering through a voice interface; your reply is read aloud "
    "by text-to-speech and heard once. Write in plain spoken prose — no "
    "markdown, no bullet lists, no code blocks, no headings, no asterisks. "
    "Keep action confirmations to one short sentence; answer questions in "
    "one or two sentences. Do not narrate what you did. Do not preamble. "
    "Just answer."
)


def _build_args(prompt: str, session_id: str | None, sandbox: str) -> list[str]:
    """Construct the codex argv for a one-shot or resume turn.

    Config overrides (sandbox + approval) are used instead of `--sandbox` / `-a`
    because `codex exec resume` rejects those flags but accepts `-c`.
    """
    overrides = [
        "-c", "approval_policy=\"never\"",
        "-c", f"sandbox_mode=\"{sandbox}\"",
    ]
    if session_id:
        # `codex exec resume <id> "<prompt>"` — positionals first, then options.
        return [
            _BIN, "exec", "resume", session_id, prompt,
            "--json", "--skip-git-repo-check", *overrides,
        ]
    return [
        _BIN, "exec", prompt,
        "--json", "--skip-git-repo-check", *overrides,
    ]


# ---------------------------------------------------------------------------
# Pure parsing / accumulation (no subprocess — directly unit-testable).
# ---------------------------------------------------------------------------


def parse_session_id(obj: dict) -> str | None:
    """Return the thread id if `obj` is a `thread.started` event, else None."""
    if obj.get("type") == "thread.started":
        tid = obj.get("thread_id")
        if isinstance(tid, str) and tid:
            return tid
    return None


def _item_preview(item: dict) -> tuple[str, str]:
    """Map a codex `item` dict → (tool_name, human preview) for display."""
    itype = item.get("type") or "tool"
    if itype == "command_execution":
        command = item.get("command") or ""
        # Reuse session_audit._preview by handing it a terminal-shaped args blob.
        return "terminal", _preview("terminal", json.dumps({"command": command}))
    if itype == "file_change":
        changes = item.get("changes") or []
        paths = [c.get("path", "") for c in changes if isinstance(c, dict)]
        first = paths[0] if paths else ""
        extra = f" (+{len(paths) - 1} more)" if len(paths) > 1 else ""
        return "edit", _preview("edit", json.dumps({"path": first})) + extra
    if itype == "mcp_tool_call":
        name = item.get("tool") or item.get("server") or "mcp"
        args_raw = item.get("arguments")
        if not isinstance(args_raw, str):
            args_raw = json.dumps(args_raw) if args_raw is not None else ""
        return name, _preview(name, args_raw)
    # Unknown executable item type — best-effort.
    return itype, ""


def _item_ok(item: dict) -> bool:
    """Best-effort success for a completed tool item."""
    if "exit_code" in item and item["exit_code"] is not None:
        return item["exit_code"] == 0
    status = item.get("status")
    if status in {"failed", "error"}:
        return False
    return True


# Item `type` values that represent a tool/command action (not assistant prose).
_TOOL_ITEM_TYPES = {"command_execution", "file_change", "mcp_tool_call"}


@dataclass
class CodexAccumulator:
    """Folds the JSONL event stream into a final StreamReply.

    `feed(obj)` returns a StreamTool to yield LIVE when a tool call starts, and
    otherwise None. After the stream ends, `build_reply()` returns the final
    StreamReply (assistant text + tool summaries + session id).
    """

    session_id: str = ""
    text: str = ""
    # tool item id → index into `tools`, so a completion can update `ok` in place.
    _index: dict = field(default_factory=dict)
    tools: list = field(default_factory=list)  # list[ToolCallSummary]

    def feed(self, obj: dict) -> StreamTool | None:
        sid = parse_session_id(obj)
        if sid:
            self.session_id = sid
            return None

        etype = obj.get("type")
        if etype not in {"item.started", "item.completed"}:
            return None
        item = obj.get("item") or {}
        itype = item.get("type")

        if itype == "agent_message":
            if etype == "item.completed":
                text = item.get("text")
                if isinstance(text, str) and text.strip():
                    # Keep the LAST non-empty assistant message as the reply
                    # (intermediate ones are reasoning narration).
                    self.text = text.strip()
            return None

        if itype in _TOOL_ITEM_TYPES:
            item_id = item.get("id")
            name, preview = _item_preview(item)
            if etype == "item.started":
                if item_id is not None and item_id not in self._index:
                    self.tools.append(
                        ToolCallSummary(name=name, preview=preview, ok=True)
                    )
                    self._index[item_id] = len(self.tools) - 1
                return StreamTool(name=name, preview=preview)
            # item.completed for a tool: record outcome.
            ok = _item_ok(item)
            if item_id is not None and item_id in self._index:
                idx = self._index[item_id]
                existing = self.tools[idx]
                self.tools[idx] = ToolCallSummary(
                    name=existing.name, preview=existing.preview, ok=ok
                )
            elif item_id is not None:
                # Completion with no prior start (shouldn't happen, but be safe).
                self.tools.append(ToolCallSummary(name=name, preview=preview, ok=ok))
                self._index[item_id] = len(self.tools) - 1
            return None

        return None

    def build_reply(self) -> StreamReply:
        return StreamReply(
            text=self.text, session_id=self.session_id, tools=list(self.tools)
        )


# ---------------------------------------------------------------------------
# Adapter
# ---------------------------------------------------------------------------


class CodexAdapter:
    """Drives `codex exec ... --json` (and `codex exec resume` for follow-ups)."""

    def __init__(self, settings: Settings):
        self._settings = settings

    def is_available(self) -> bool:
        return shutil.which(_BIN) is not None

    def describe(self) -> dict:
        return {
            "bin": _BIN,
            "available": self.is_available(),
            "timeout_seconds": self._settings.hermes_timeout,
            "workspace_dir": self._settings.harness_workspace_dir,
            "sandbox": self._settings.harness_sandbox,
        }

    def _workspace(self) -> str:
        wd = self._settings.harness_workspace_dir
        os.makedirs(wd, exist_ok=True)
        return wd

    async def ask(self, prompt: str, session_id: str | None = None) -> HermesReply:
        if not prompt.strip():
            raise HermesError("empty prompt")

        shaped = prompt
        if _VOICE_PRELUDE and not session_id:
            shaped = f"{_VOICE_PRELUDE}\n\n{prompt}"

        args = _build_args(shaped, session_id, self._settings.harness_sandbox)
        cwd = self._workspace()

        try:
            proc = await asyncio.create_subprocess_exec(
                *args,
                cwd=cwd,
                stdin=asyncio.subprocess.DEVNULL,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
        except FileNotFoundError as e:
            raise HermesError(f"codex binary not found: {_BIN}") from e

        try:
            stdout_b, stderr_b = await asyncio.wait_for(
                proc.communicate(), timeout=self._settings.hermes_timeout
            )
        except asyncio.TimeoutError as e:
            proc.kill()
            raise HermesError(
                f"codex timed out after {self._settings.hermes_timeout}s"
            ) from e

        stdout = stdout_b.decode("utf-8", errors="replace")
        stderr = stderr_b.decode("utf-8", errors="replace")

        if proc.returncode != 0:
            tail = (stderr or stdout).strip().splitlines()[-5:]
            raise HermesError(
                f"codex exited {proc.returncode}: " + " | ".join(tail)
            )

        acc = CodexAccumulator(session_id=session_id or "")
        for line in stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            acc.feed(obj)

        if not acc.text:
            raise HermesError("codex returned no assistant text")
        return HermesReply(text=acc.text, session_id=acc.session_id)

    async def ask_streaming(
        self, prompt: str, session_id: str | None = None
    ) -> AsyncIterator[StreamTool | StreamReply]:
        if not prompt.strip():
            raise HermesError("empty prompt")

        shaped = prompt
        if _VOICE_PRELUDE and not session_id:
            shaped = f"{_VOICE_PRELUDE}\n\n{prompt}"

        args = _build_args(shaped, session_id, self._settings.harness_sandbox)
        cwd = self._workspace()

        try:
            proc = await asyncio.create_subprocess_exec(
                *args,
                cwd=cwd,
                stdin=asyncio.subprocess.DEVNULL,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL,
            )
        except FileNotFoundError as e:
            raise HermesError(f"codex binary not found: {_BIN}") from e

        acc = CodexAccumulator(session_id=session_id or "")
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
                    tool = acc.feed(obj)
                    if tool is not None:
                        yield tool
        except TimeoutError as e:
            proc.kill()
            await proc.wait()
            raise HermesError(
                f"codex timed out after {self._settings.hermes_timeout}s"
            ) from e
        await proc.wait()

        if not acc.text:
            raise HermesError("codex returned no assistant text")
        yield acc.build_reply()
