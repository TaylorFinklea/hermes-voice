"""Map a tool call to a warm, casual, first-person spoken filler phrase.

Pure + side-effect-free so it can run inline in the ACP receive loop (see
acp_client._process_update) and be unit-tested in isolation. Returns a short
phrase to speak while a tool runs — or None when narrating would be noise
(internal/bland tools), so we stay quiet rather than say something useless.

Voice: WARM, CASUAL, FIRST-PERSON — "let me look that up", "checking the
weather for you" — matching the spoken-filler tone used elsewhere. On-device
turns use tts="none", so iOS speaks these via AVSpeech (never server-synthesized).

The `name` here is the ACP tool *title* prefix from acp_client._split_title
(e.g. "terminal", "read", "search", "fetch", "weather") — a human label, not a
function id — so matching is on substrings of that label, case-insensitive.
"""
from __future__ import annotations


def _arg(args: dict | None, *keys: str) -> str | None:
    """First non-empty string value among `keys` in `args` (case-insensitive
    key match), trimmed. None if absent — callers stay quiet on missing args."""
    if not args:
        return None
    lowered = {str(k).lower(): v for k, v in args.items()}
    for k in keys:
        v = lowered.get(k.lower())
        if isinstance(v, str) and v.strip():
            return v.strip()
    return None


def tool_narration(
    name: str,
    preview: str | None = None,
    args: dict | None = None,
) -> str | None:
    """A warm, casual, first-person phrase to speak while a tool runs.

    Returns None for tools not worth narrating (internal/noisy), so the caller
    emits nothing rather than something bland.
    """
    n = (name or "").strip().lower()
    if not n:
        return None

    # Internal / noisy tools we never narrate — stay quiet.
    if any(k in n for k in ("think", "todo", "plan", "switch_mode", "memory")):
        return None

    # Weather — enrich with a location from args when present.
    if "weather" in n:
        loc = _arg(args, "location", "city", "place", "query", "q")
        if loc:
            return f"Checking the weather in {loc}."
        return "Checking the weather for you."

    # Calendar / schedule.
    if any(k in n for k in ("calendar", "schedule", "event")):
        return "Checking your calendar."

    # Web / fetch / browse — looking something up online.
    if any(k in n for k in ("web", "fetch", "browse", "url", "http", "google")):
        return "Let me look that up online."

    # File search / grep / find.
    if any(k in n for k in ("search", "grep", "find")):
        return "Searching through your files."

    # Reading / listing files.
    if any(k in n for k in ("read", "file", "list", "glob", "cat")):
        return "Let me pull that up."

    # Terminal / shell / bash / exec.
    if any(k in n for k in ("terminal", "bash", "shell", "exec", "run", "command")):
        return "Alright, let me run that."

    # Known-but-bland tools → one soft fallback so the silence isn't dead air.
    return "Let me look into that."
