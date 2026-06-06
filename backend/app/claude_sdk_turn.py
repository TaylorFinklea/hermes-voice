"""Phase B: a Claude turn driven through the Claude Agent SDK with voice-mediated
tool approval. Used for WRITE turns on an attached Claude session — writes and
commands pause for a voice yes/no (the `can_use_tool` callback), and the agent
can ask the user structured questions (the `ask_user` MCP tool). Safe reads
auto-approve.

It yields the same SSE event shapes as `_stream_turn`
(transcribed/tool/assistant/audio/done/error) PLUS the bidirectional events the
ApprovalBroker bridges to `POST /api/turns/{id}/answer`:
  - {"type": "turn", "turn_id": ...}   sent first so the client knows where to answer
  - {"type": "approval_request", "request_id", "tool", "title", "preview"}
  - {"type": "question", "request_id", "prompt", "options", "multi"}

The SDK turn runs in a task that pushes message events onto the broker's queue;
`can_use_tool` / `ask_user` push request events and await the answer; the
generator drains the one queue and yields everything to the client.
"""
from __future__ import annotations

import asyncio
import json
import logging
from collections.abc import AsyncIterator

from claude_agent_sdk import (
    AssistantMessage,
    ClaudeAgentOptions,
    ClaudeSDKClient,
    PermissionResultAllow,
    PermissionResultDeny,
    ResultMessage,
    TextBlock,
    ToolUseBlock,
    create_sdk_mcp_server,
    tool,
)

from .adapters.claude import _VOICE_SYSTEM_PROMPT, session_cwd_from_disk
from .session_audit import _preview

logger = logging.getLogger("hermes_voice")


def _preview_args(name: str, raw_input: object) -> str:
    try:
        return _preview(name, json.dumps(raw_input) if raw_input is not None else "")
    except (TypeError, ValueError):
        return ""


async def stream_claude_approval_turn(
    app,
    *,
    user_text: str,
    session_id: str | None,
    voice_id: str | None = None,
    tts_mode: str | None = None,
) -> AsyncIterator[dict]:
    """SSE event generator for a write-enabled, voice-approved Claude turn."""
    broker = app.state.approvals
    settings = app.state.settings
    tts = app.state.tts

    # Resume in the session's real repo (writes happen there, with approval).
    cwd = (session_cwd_from_disk(session_id) if session_id else None) or (
        settings.harness_workspace_dir
    )

    turn_id = broker.open()

    async def run() -> None:
        try:
            await _drive(
                broker, turn_id, app, tts,
                user_text=user_text, session_id=session_id, cwd=cwd,
                voice_id=voice_id, tts_mode=tts_mode,
            )
        except asyncio.CancelledError:
            raise
        except Exception as e:  # noqa: BLE001
            logger.warning("claude SDK turn error: %s", e)
            broker.emit(turn_id, {"type": "error", "detail": f"claude failed: {e}"})
        finally:
            broker.close(turn_id)

    task = asyncio.create_task(run())
    yield {"type": "turn", "turn_id": turn_id}
    yield {"type": "transcribed", "text": user_text}
    try:
        async for event in broker.events(turn_id):
            yield event
    finally:
        if not task.done():
            task.cancel()
            try:
                await task
            except (asyncio.CancelledError, Exception):
                pass


async def _drive(
    broker, turn_id, app, tts,
    *, user_text: str, session_id: str | None, cwd: str,
    voice_id: str | None, tts_mode: str | None,
) -> None:
    async def can_use_tool(tool_name, tool_input, ctx):
        """Pause a risky tool (write / command) for a voice yes/no."""
        decision = await broker.request(turn_id, {
            "type": "approval_request",
            "tool": tool_name,
            "title": getattr(ctx, "title", None) or f"Allow {tool_name}?",
            "preview": _preview_args(tool_name, tool_input),
        })
        if decision in ("allow", "yes", True):
            return PermissionResultAllow()
        return PermissionResultDeny(message="Declined by voice.")

    @tool(
        "ask_user",
        "Ask the user a single- or multi-select question and wait for their "
        "spoken answer. Use this for clarifications instead of guessing.",
        {"question": str, "options": list, "multi": bool},
    )
    async def ask_user(args):
        answer = await broker.request(turn_id, {
            "type": "question",
            "prompt": str(args.get("question", "")),
            "options": list(args.get("options") or []),
            "multi": bool(args.get("multi", False)),
        })
        text = ", ".join(answer) if isinstance(answer, list) else str(answer)
        return {"content": [{"type": "text", "text": text or "(no answer)"}]}

    ask_server = create_sdk_mcp_server(name="voice", version="1.0.0", tools=[ask_user])

    # Voice-shape every turn via the system prompt (applied on resume too), not
    # a first-turn user prefix. MUST be the preset+append dict — a bare str maps
    # to --system-prompt and REPLACES Claude Code's default prompt (breaks tool
    # use / CLAUDE.md loading), and None maps to --system-prompt "" which wipes
    # it. preset+append maps to --append-system-prompt and preserves the default.
    shaped = user_text
    options = ClaudeAgentOptions(
        permission_mode="default",          # safe reads auto; writes/cmds -> can_use_tool
        cwd=cwd,
        resume=session_id or None,
        can_use_tool=can_use_tool,
        mcp_servers={"voice": ask_server},
        allowed_tools=["mcp__voice__ask_user"],
        setting_sources=["project"],        # load the repo's CLAUDE.md; skip global hooks
        system_prompt={
            "type": "preset",
            "preset": "claude_code",
            "append": _VOICE_SYSTEM_PROMPT,
        },
    )

    final_text = ""
    async with ClaudeSDKClient(options=options) as client:
        await client.query(shaped)
        async for msg in client.receive_response():
            if isinstance(msg, AssistantMessage):
                for block in msg.content:
                    if isinstance(block, TextBlock) and block.text.strip():
                        final_text = block.text.strip()
                    elif isinstance(block, ToolUseBlock):
                        broker.emit(turn_id, {
                            "type": "tool",
                            "name": block.name,
                            "preview": _preview_args(block.name, block.input),
                            "ok": True,
                        })
            elif isinstance(msg, ResultMessage):
                sid = msg.session_id or (session_id or "")
                text = (msg.result or final_text or "").strip()
                if not text:
                    broker.emit(turn_id, {
                        "type": "error",
                        "detail": "claude returned no assistant text",
                    })
                    return
                broker.emit(turn_id, {"type": "assistant", "text": text, "session_id": sid})
                if tts is not None and text and tts_mode != "none":
                    try:
                        from .main import _start_stream
                        from .speakable import make_speakable
                        # Speak the de-markdowned copy; the emitted assistant
                        # text above stays raw for the transcript.
                        audio_url = _start_stream(app, tts, make_speakable(text), voice_id=voice_id)
                        if audio_url:
                            broker.emit(turn_id, {"type": "audio", "url": audio_url})
                    except Exception as e:  # noqa: BLE001
                        logger.warning("claude SDK turn tts error: %s", e)
                broker.emit(turn_id, {"type": "done", "session_id": sid})
                return
