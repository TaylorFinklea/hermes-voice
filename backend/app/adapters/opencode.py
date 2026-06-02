"""Wrap the `opencode` CLI as a HarnessClient adapter.

OpenCode runs as a cwd-scoped coding agent. We drive it headless with
`opencode run "<message>" --format json`, which streams raw JSON events to
stdout (one JSON object per line). Each iOS conversation maps to an OpenCode
session id (`ses_...`); we capture it from the run events and pass it back via
`--session <id>` on subsequent turns so OpenCode keeps its context.

Non-interactive + workspace-write WITHOUT a full bypass: we pass an inline
config via the `OPENCODE_CONFIG_CONTENT` env var (highest-precedence config
source) that sets the `edit` and `bash` permissions to "allow". This auto-
approves edits and shell commands so a headless run never blocks on an
approval prompt, while leaving everything else at OpenCode's defaults — we do
NOT use `--dangerously-skip-permissions`, which auto-approves *all* tools
(a full bypass). OpenCode already sandboxes the run to the working directory
(`--dir <workspace>`); edits outside it hit the `external_directory` permission
(default "ask"), so the allow-list stays scoped to the workspace.

Event shapes (captured from `opencode run --format json`, v1.15.13):
    {"type":"step_start","sessionID":"ses_...","part":{"type":"step-start",...}}
    {"type":"text","sessionID":"ses_...",
        "part":{"type":"text","text":"hello",
                "metadata":{"openai":{"phase":"final_answer"}}}}
    {"type":"tool_use","sessionID":"ses_...",
        "part":{"type":"tool","tool":"read","callID":"call_...",
                "state":{"status":"completed","input":{...},...}}}
    {"type":"step_finish","sessionID":"ses_...","part":{"type":"step-finish",...}}

Security: asyncio.create_subprocess_exec with an explicit argv list (never
shell=True), so prompts and session ids cannot inject shell metacharacters.

PARSING is separated from the SUBPROCESS: `parse_event` and `Accumulator`
below are pure functions over already-decoded JSON dicts, so they can be tested
with canned events and no subprocess.
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

# Inline OpenCode config that makes a headless run non-interactive with
# workspace-write: auto-approve file edits and shell commands so no approval
# prompt can hang the run. NOT a full bypass — only `edit`/`bash` are allowed;
# `external_directory` (writes outside --dir) stays at its default "ask" and so
# is effectively denied in a headless run, keeping the allow-list scoped to the
# workspace.
_PERMISSION_CONFIG = json.dumps(
    {"permission": {"edit": "allow", "bash": "allow"}}
)


@dataclass
class Accumulator:
    """Folds a stream of parsed OpenCode events into a final turn result.

    `text` keeps the authoritative assistant reply (the text part marked
    `final_answer`, else the last non-empty text part — robust across providers
    that don't emit the `phase` marker). `tools` is the ordered tool list and
    `session_id` is captured from any event that carries one.
    """

    text: str = ""
    _have_final: bool = False
    session_id: str = ""
    tools: list[ToolCallSummary] = field(default_factory=list)

    def add_text(self, text: str, is_final: bool) -> None:
        if not text.strip():
            return
        if self._have_final and not is_final:
            return  # never let trailing commentary clobber the final answer
        if is_final:
            self.text = text.strip()
            self._have_final = True
        else:
            self.text = text.strip()

    def add_tool(self, tool: ToolCallSummary) -> None:
        self.tools.append(tool)

    def set_session(self, session_id: str) -> None:
        if session_id:
            self.session_id = session_id


def _text_is_final(part: dict) -> bool:
    """True if a text part is the model's final answer (provider-specific).

    OpenAI-backed runs tag the final text part with
    metadata.openai.phase == "final_answer" and intermediate narration with
    "commentary". Other providers may omit this; callers fall back to the last
    non-empty text part.
    """
    meta = part.get("metadata")
    if not isinstance(meta, dict):
        return False
    for provider_meta in meta.values():
        if isinstance(provider_meta, dict):
            if provider_meta.get("phase") == "final_answer":
                return True
    return False


def _tool_summary(part: dict) -> ToolCallSummary | None:
    """Build a ToolCallSummary from a `type:"tool"` part, or None if not ready.

    `state.input` is a dict in OpenCode's events; `_preview` wants a JSON
    string, so we re-serialize it. `ok` comes from the tool state: a
    "completed" status with no error is success.
    """
    name = part.get("tool") or "tool"
    state = part.get("state")
    if not isinstance(state, dict):
        return None
    status = state.get("status")
    # Skip parts that haven't produced a result yet (pending/running) — the
    # terminal event for the same callID arrives later and is summarized then.
    if status not in ("completed", "error"):
        return None
    raw_input = state.get("input")
    if isinstance(raw_input, (dict, list)):
        args_raw = json.dumps(raw_input)
    elif isinstance(raw_input, str):
        args_raw = raw_input
    else:
        args_raw = ""
    ok = status == "completed" and not state.get("error")
    return ToolCallSummary(name=name, preview=_preview(name, args_raw), ok=ok)


def parse_event(obj: dict) -> StreamTool | None:
    """Translate one raw OpenCode event into a live StreamTool, or None.

    Pure: takes an already-decoded JSON dict. Only tool-use events that have
    reached a terminal state produce a StreamTool (for the live preview feed);
    text/step events return None and are folded by the Accumulator instead.
    """
    if not isinstance(obj, dict):
        return None
    part = obj.get("part")
    if not isinstance(part, dict):
        return None
    if part.get("type") != "tool":
        return None
    summary = _tool_summary(part)
    if summary is None:
        return None
    return StreamTool(name=summary.name, preview=summary.preview)


def fold_event(acc: Accumulator, obj: dict) -> StreamTool | None:
    """Update `acc` from one event and return a StreamTool to yield live (or None).

    This is the single place that drives accumulation: it records the session
    id, appends tool summaries, captures assistant text, and — for terminal
    tool events — returns the StreamTool the caller should yield immediately.
    Pure over decoded dicts.
    """
    if not isinstance(obj, dict):
        return None

    sid = obj.get("sessionID") or obj.get("sessionId")
    if isinstance(sid, str):
        acc.set_session(sid)

    part = obj.get("part")
    if not isinstance(part, dict):
        return None

    # Some events nest the session id only inside the part.
    psid = part.get("sessionID") or part.get("sessionId")
    if isinstance(psid, str):
        acc.set_session(psid)

    ptype = part.get("type")
    if ptype == "text":
        text = part.get("text")
        if isinstance(text, str):
            acc.add_text(text, _text_is_final(part))
        return None
    if ptype == "tool":
        summary = _tool_summary(part)
        if summary is None:
            return None
        acc.add_tool(summary)
        return StreamTool(name=summary.name, preview=summary.preview)
    return None


class OpenCodeAdapter:
    """Drives `opencode run --format json` (and `--session <id>` for follow-ups)."""

    bin = "opencode"

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
        }

    def _base_args(self, prompt: str, session_id: str | None) -> list[str]:
        workspace = self._settings.harness_workspace_dir
        args = [self.bin, "run", prompt, "--format", "json", "--dir", workspace]
        if session_id:
            args.extend(["--session", session_id])
        return args

    def _spawn_env(self) -> dict:
        env = os.environ.copy()
        # Inline config (highest-precedence source) → non-interactive
        # workspace-write without --dangerously-skip-permissions.
        env["OPENCODE_CONFIG_CONTENT"] = _PERMISSION_CONFIG
        return env

    def _workspace(self) -> str:
        workspace = self._settings.harness_workspace_dir
        os.makedirs(workspace, exist_ok=True)
        return workspace

    async def ask(
        self, prompt: str, session_id: str | None = None
    ) -> HermesReply:
        if not prompt.strip():
            raise HermesError("empty prompt")
        workspace = self._workspace()
        args = self._base_args(prompt, session_id)

        try:
            proc = await asyncio.create_subprocess_exec(
                *args,
                cwd=workspace,
                env=self._spawn_env(),
                stdin=asyncio.subprocess.DEVNULL,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
        except FileNotFoundError as e:
            raise HermesError(f"opencode binary not found: {self.bin}") from e

        try:
            stdout_b, stderr_b = await asyncio.wait_for(
                proc.communicate(), timeout=self._settings.hermes_timeout
            )
        except asyncio.TimeoutError as e:
            proc.kill()
            await proc.wait()
            raise HermesError(
                f"opencode timed out after {self._settings.hermes_timeout}s"
            ) from e

        if proc.returncode != 0:
            stderr = stderr_b.decode("utf-8", errors="replace")
            stdout = stdout_b.decode("utf-8", errors="replace")
            tail = (stderr or stdout).strip().splitlines()[-5:]
            raise HermesError(
                f"opencode exited {proc.returncode}: " + " | ".join(tail)
            )

        acc = Accumulator()
        acc.set_session(session_id or "")
        for line in stdout_b.decode("utf-8", errors="replace").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            fold_event(acc, obj)

        if not acc.text:
            raise HermesError("opencode returned no assistant text")
        return HermesReply(text=acc.text, session_id=acc.session_id)

    async def ask_streaming(
        self, prompt: str, session_id: str | None = None
    ) -> AsyncIterator[StreamTool | StreamReply]:
        if not prompt.strip():
            raise HermesError("empty prompt")
        workspace = self._workspace()
        args = self._base_args(prompt, session_id)

        try:
            proc = await asyncio.create_subprocess_exec(
                *args,
                cwd=workspace,
                env=self._spawn_env(),
                stdin=asyncio.subprocess.DEVNULL,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL,
            )
        except FileNotFoundError as e:
            raise HermesError(f"opencode binary not found: {self.bin}") from e

        acc = Accumulator()
        acc.set_session(session_id or "")
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
                    tool = fold_event(acc, obj)
                    if tool is not None:
                        yield tool
        except TimeoutError as e:
            proc.kill()
            await proc.wait()
            raise HermesError(
                f"opencode timed out after {self._settings.hermes_timeout}s"
            ) from e
        await proc.wait()

        if not acc.text:
            raise HermesError("opencode returned no assistant text")
        yield StreamReply(
            text=acc.text, session_id=acc.session_id, tools=list(acc.tools)
        )
