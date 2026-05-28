"""Wrap the local `hermes` CLI as an awaitable client.

Each iOS conversation maps to a Hermes session_id. We capture it from the
quiet-mode output and pass it back via --resume on subsequent turns, so Hermes
keeps its tool/context memory across the voice exchange.

Quiet output format (verified with `hermes chat -Q`):
    stdout: <assistant response, possibly multi-line>
    stderr: a `session_id: <id>` line (and any `↻ Resumed session ...` notice)

Security: we use asyncio.create_subprocess_exec with an explicit argv list
(never shell=True), so user prompts cannot inject shell metacharacters.
"""
from __future__ import annotations

import asyncio
import re
import shutil
from dataclasses import dataclass

from .config import Settings

_SESSION_RE = re.compile(r"^session_id:\s*(\S+)\s*$", re.MULTILINE)


class HermesError(RuntimeError):
    """Raised when the hermes CLI fails or output cannot be parsed."""


# Prepended to the FIRST turn of every voice-originated conversation.
# Shapes Hermes' delivery for TTS playback: no markdown, no lists, length
# matched to the task type. Skipped on --resume turns since Hermes carries
# it via session context.
#
# Design principle: the user already SEES which tools you called and their
# outcomes in a visual audit row above your spoken reply. So the spoken
# text doesn't need to describe what was done — only confirm the result.
# This is the difference between "I've saved your thought to your Logseq
# daily journal under the 'ideas' heading" (10 seconds of TTS) and
# "Saved." (0.5 seconds).
_VOICE_PRELUDE = (
    "You are answering through a voice interface; your reply is read aloud "
    "by text-to-speech and heard once. Write in plain spoken prose — no "
    "markdown, no bullet lists, no code blocks, no headings, no asterisks. "
    "\n\n"
    "The user can see, in a visual audit row above your spoken reply, "
    "exactly which tools you called and what they did. Do NOT narrate "
    "what you did — only confirm the result. The spoken text should be "
    "the shortest sentence that lets the user verify the right thing "
    "happened."
    "\n\n"
    "Length rules by task type:\n"
    "- Action completed (saving notes, setting reminders, writing files, "
    "playing music, controlling devices, sending messages): one short "
    "sentence. Examples: \"Saved.\" \"Reminder set for five PM.\" "
    "\"Playing focus music.\" \"Done.\" Do NOT recite what you saved or "
    "where — the audit row already shows it.\n"
    "- Information answered (calendar, weather, status, lookups, "
    "research): one or two sentences with the actual answer.\n"
    "- Conversational or open-ended: a few sentences as needed, no more.\n"
    "- Multiple actions in one turn: combine confirmations into ONE "
    "sentence: \"Saved and reminder set for tomorrow.\"\n"
    "- Action FAILED: say so plainly with the reason. Do not minimize."
    "\n\n"
    "Do not repeat my question back. Do not preamble with \"Sure,\" "
    "\"I'll,\" \"Let me,\" or \"Here's.\" Just answer."
)


@dataclass(frozen=True)
class HermesReply:
    text: str
    session_id: str


class HermesClient:
    """Calls `hermes chat -Q -q <prompt>` (and --resume <id> for follow-ups)."""

    def __init__(self, settings: Settings):
        self._settings = settings

    def is_available(self) -> bool:
        return shutil.which(self._settings.hermes_bin) is not None

    def describe(self) -> dict:
        return {
            "bin": self._settings.hermes_bin,
            "available": self.is_available(),
            "timeout_seconds": self._settings.hermes_timeout,
            "extra_args": list(self._settings.hermes_extra_args),
        }

    async def ask(self, prompt: str, session_id: str | None = None) -> HermesReply:
        if not prompt.strip():
            raise HermesError("empty prompt")

        # Only prepend on the FIRST turn — Hermes carries it via session
        # context after that, so we save tokens on resumes.
        shaped = prompt
        if _VOICE_PRELUDE and not session_id:
            shaped = f"{_VOICE_PRELUDE}\n\n{prompt}"

        args = [self._settings.hermes_bin, "chat", "-Q", "-q", shaped]
        args.extend(self._settings.hermes_extra_args)
        if session_id:
            args.extend(["--resume", session_id])

        spawn = asyncio.create_subprocess_exec
        try:
            proc = await spawn(
                *args,
                stdin=asyncio.subprocess.DEVNULL,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
        except FileNotFoundError as e:
            raise HermesError(f"hermes binary not found: {self._settings.hermes_bin}") from e

        try:
            stdout_b, stderr_b = await asyncio.wait_for(
                proc.communicate(), timeout=self._settings.hermes_timeout
            )
        except asyncio.TimeoutError as e:
            proc.kill()
            raise HermesError(
                f"hermes timed out after {self._settings.hermes_timeout}s"
            ) from e

        stdout = stdout_b.decode("utf-8", errors="replace")
        stderr = stderr_b.decode("utf-8", errors="replace")

        if proc.returncode != 0:
            tail = (stderr or stdout).strip().splitlines()[-5:]
            raise HermesError(
                f"hermes exited {proc.returncode}: " + " | ".join(tail)
            )

        return self._parse(stdout, stderr)

    @staticmethod
    def _parse(stdout: str, stderr: str) -> HermesReply:
        # On --resume, hermes prints a "↻ Resumed session ..." notice to stdout
        # before the response. Strip any leading notice lines (start with ↻).
        lines = stdout.replace("\r\n", "\n").splitlines()
        while lines and lines[0].lstrip().startswith("↻"):
            lines.pop(0)
        text = "\n".join(lines).strip()
        if not text:
            raise HermesError("hermes returned no assistant text")
        # session_id is emitted on stderr in quiet mode.
        match = _SESSION_RE.search(stderr)
        session_id = match.group(1) if match else ""
        return HermesReply(text=text, session_id=session_id)


class MockHermesClient(HermesClient):
    """In-memory canned-response client for tests and mock mode."""

    def __init__(self, settings: Settings, reply: str = "Mock Hermes here. I heard you."):
        super().__init__(settings)
        self._reply = reply
        self._counter = 0

    def is_available(self) -> bool:
        return True

    def describe(self) -> dict:
        return {"bin": "mock", "available": True, "mock": True}

    async def ask(self, prompt: str, session_id: str | None = None) -> HermesReply:
        self._counter += 1
        sid = session_id or f"mock-{self._counter:06d}"
        return HermesReply(text=f"{self._reply} (you said: {prompt!r})", session_id=sid)
