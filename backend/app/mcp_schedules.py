"""Stdio MCP server exposing Hermes Voice schedules to the Hermes Agent.

Hermes Agent registers this as an MCP server (`hermes mcp add hermes-voice
--command uv --args run python -m app.mcp_schedules`). When the user says
"every 5 min give me the weather," Hermes interprets the cadence + topic
and calls `create_schedule` here, which POSTs to our REST backend.

The server is intentionally a thin proxy — all storage + cron logic lives
in `app.schedules` and the FastAPI app. We just translate MCP tool calls
to HTTP calls. This means a single backend instance can serve multiple
Hermes profiles / sessions cleanly.

Configuration (env):
- HERMES_VOICE_BASE_URL   default http://127.0.0.1:8765
- HERMES_VOICE_TOKEN      same token the iOS app uses (X-Hermes-Voice-Token)
- HERMES_VOICE_CA_BUNDLE  optional path to a PEM-encoded CA bundle. Set
                          this if your backend uses a TLS cert signed by
                          a custom CA (rare — Tailscale-issued certs chain
                          to Let's Encrypt and verify out of the box).

Voice grammar examples Hermes is expected to translate:
- "Every 5 minutes give me the weather"
  → create_schedule(cadence_seconds=300, prompt="give me the weather",
                    display_name="weather updates")
- "What's scheduled?"
  → list_schedules()
- "Stop the weather updates"
  → list_schedules() to find match, then delete_schedule(id=...)
"""
from __future__ import annotations

import logging
import os
from pathlib import Path
from typing import Any

import httpx
from dotenv import load_dotenv
from mcp.server.fastmcp import FastMCP

logger = logging.getLogger("hermes_voice.mcp")

# Load backend/.env so the MCP server shares the backend's single source of
# truth for HERMES_VOICE_TOKEN (and base URL if set there). Path is relative
# to this file, so it works regardless of the cwd Hermes spawns us in.
# override=False lets explicit --env values passed by `hermes mcp add` win.
_ENV_PATH = Path(__file__).resolve().parent.parent / ".env"
if _ENV_PATH.exists():
    load_dotenv(_ENV_PATH, override=False)

# Loaded fresh on every tool call so a backend URL/token change doesn't
# require restarting Hermes.
def _client() -> httpx.AsyncClient:
    base = os.environ.get("HERMES_VOICE_BASE_URL", "http://127.0.0.1:8765")
    token = os.environ.get("HERMES_VOICE_TOKEN", "")
    headers = {}
    if token:
        headers["X-Hermes-Voice-Token"] = token
    # TLS: default to httpx's standard verification (system trust store +
    # certifi). If the user has a custom CA — e.g. a homegrown self-signed
    # cert they actually want to use — they set HERMES_VOICE_CA_BUNDLE
    # rather than us silently disabling verification.
    verify: bool | str = True
    if ca := os.environ.get("HERMES_VOICE_CA_BUNDLE"):
        verify = ca
    return httpx.AsyncClient(
        base_url=base.rstrip("/"),
        headers=headers,
        timeout=10.0,
        verify=verify,
    )


server = FastMCP("hermes-voice-schedules")


@server.tool()
async def create_schedule(
    cadence_seconds: int,
    prompt: str,
    display_name: str | None = None,
) -> dict[str, Any]:
    """Create a recurring Hermes message.

    Args:
        cadence_seconds: How often to fire, in seconds. Minimum 60.
            Common conversions: 5 minutes = 300; 1 hour = 3600; daily = 86400.
        prompt: The exact prompt sent to Hermes each fire. No preamble —
            just what you want Hermes to do. E.g. "give me the weather"
            or "summarize my unread emails".
        display_name: A short label users see in the iOS Schedules list.
            E.g. "weather updates", "morning briefing".

    Returns:
        The created schedule with id, next_fire_at (unix timestamp), and
        all other fields. Tell the user the display_name + the cadence
        in human-friendly terms ("every 5 minutes").
    """
    async with _client() as c:
        r = await c.post(
            "/api/schedules",
            json={
                "cadence_seconds": cadence_seconds,
                "prompt": prompt,
                "display_name": display_name,
            },
        )
        r.raise_for_status()
        return r.json()


@server.tool()
async def list_schedules() -> list[dict[str, Any]]:
    """List all currently configured recurring messages.

    Returns:
        Array of schedules with id, display_name, cadence_seconds,
        prompt, enabled, next_fire_at. Use this to find a schedule
        by display_name when the user says "stop the weather updates".
    """
    async with _client() as c:
        r = await c.get("/api/schedules")
        r.raise_for_status()
        return r.json()


@server.tool()
async def delete_schedule(
    id: str | None = None,
    display_name_match: str | None = None,
) -> dict[str, Any]:
    """Delete a recurring message. Either id or display_name_match required.

    Args:
        id: Exact schedule id (from list_schedules). Preferred when you have it.
        display_name_match: Case-insensitive substring of the display_name.
            Use this when the user says "stop the weather updates" — match
            "weather" against existing display_names. If multiple match,
            returns an error listing them so the user can disambiguate.

    Returns:
        {deleted: bool, id: str, display_name: str} on success.
        On no-match: {error: "no matching schedule", candidates: [...]}.
        On multi-match: {error: "ambiguous", candidates: [...]}.
    """
    if not id and not display_name_match:
        return {"error": "must provide id or display_name_match"}

    async with _client() as c:
        if not id:
            r = await c.get("/api/schedules")
            r.raise_for_status()
            schedules = r.json()
            needle = (display_name_match or "").lower()
            matches = [
                s for s in schedules
                if needle and needle in (s.get("display_name") or "").lower()
            ]
            if not matches:
                return {
                    "error": "no matching schedule",
                    "candidates": [s.get("display_name") for s in schedules],
                }
            if len(matches) > 1:
                return {
                    "error": "ambiguous match",
                    "candidates": [s.get("display_name") for s in matches],
                }
            id = matches[0]["id"]
            target_name = matches[0].get("display_name")
        else:
            target_name = None

        r = await c.delete(f"/api/schedules/{id}")
        if r.status_code == 404:
            return {"error": "schedule not found", "id": id}
        r.raise_for_status()
        return {"deleted": True, "id": id, "display_name": target_name}


def main() -> None:
    """Run the stdio MCP server. Invoked by Hermes Agent as a subprocess."""
    logging.basicConfig(level=logging.WARNING)  # keep stdio clean for protocol
    server.run()


if __name__ == "__main__":
    main()
