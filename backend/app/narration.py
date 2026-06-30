"""Map a tool call to a warm, casual, first-person spoken filler phrase.

Called inline in the ACP receive loop (see acp_client._process_update) to pick a
short phrase to speak while a tool runs — or None when narrating would be noise
(internal/bland tools), so we stay quiet rather than say something useless.

Each tool family has SEVERAL interchangeable phrasings (NARRATION_PHRASES), and
`tool_narration` never returns the same phrase twice in a row (module-level
`_last_phrase`) — so a run of same-family tool calls ("search… search… search")
doesn't speak one identical sentence over and over. Selection is otherwise
random. This is the one bit of state in the module; it's cosmetic-only and the
ACP loop is single-threaded (asyncio), so the shared `_last_phrase` is safe.

Voice: WARM, CASUAL, FIRST-PERSON — "let me look that up", "checking the
weather for you" — matching the spoken-filler tone used elsewhere. On-device
turns use tts="none", so iOS speaks these via AVSpeech (never server-synthesized).

The `name` here is the ACP tool *title* prefix from acp_client._split_title
(e.g. "terminal", "read", "search", "fetch", "weather") — a human label, not a
function id — so matching is on substrings of that label, case-insensitive.
"""
from __future__ import annotations

import random

# Interchangeable phrasings per tool family. Within a family every variant keeps
# the same salient keyword (terminal→"run", search→"search", web→"online") so the
# family stays recognizable and substring tests hold; the rest of the wording
# varies so repeated same-family calls don't sound identical.
NARRATION_PHRASES: dict[str, tuple[str, ...]] = {
    "terminal": (
        "Alright, let me run that.",
        "Let me run that for you.",
        "Running that now.",
        "On it — running that.",
        "Okay, let me go run that.",
        "Let me run that real quick.",
    ),
    "search": (
        "Searching through your files.",
        "Let me search for that.",
        "Searching now.",
        "On it — searching your files.",
        "Let me search through these.",
        "Searching that for you.",
    ),
    "web": (
        "Let me look that up online.",
        "Looking that up online.",
        "Let me find that online.",
        "Checking online for that.",
        "Let me search online for you.",
        "Looking online now.",
    ),
    "read": (
        "Let me pull that up.",
        "Let me take a look at that.",
        "Pulling that up now.",
        "Let me open that up.",
        "Let me read through that.",
        "Taking a look now.",
    ),
    "calendar": (
        "Checking your calendar.",
        "Let me check your calendar.",
        "Looking at your calendar now.",
        "Let me see what's on your calendar.",
        "Checking your schedule.",
        "Pulling up your calendar.",
    ),
    "weather": (
        "Checking the weather for you.",
        "Let me check the weather.",
        "Looking up the weather now.",
        "Let me pull up the forecast.",
        "Checking the forecast for you.",
        "Let me see what the weather's like.",
    ),
    "fallback": (
        "Let me look into that.",
        "Let me dig into that.",
        "On it — let me check that.",
        "Let me take care of that.",
        "Looking into that now.",
        "Let me handle that.",
    ),
}

# The phrase returned by the previous call, so we never repeat it consecutively.
_last_phrase: str | None = None


def _remember(phrase: str) -> str:
    """Record `phrase` as the last spoken one and return it unchanged."""
    global _last_phrase
    _last_phrase = phrase
    return phrase


def _pick(family: str) -> str:
    """A random variant for `family`, never equal to the previous phrase."""
    options = NARRATION_PHRASES[family]
    pool = [p for p in options if p != _last_phrase] or list(options)
    return _remember(random.choice(pool))


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
    emits nothing rather than something bland. Never returns the same phrase as
    the immediately-preceding call (see module docstring).
    """
    n = (name or "").strip().lower()
    if not n:
        return None

    # Internal / noisy tools we never narrate — stay quiet.
    if any(k in n for k in ("think", "todo", "plan", "switch_mode", "memory")):
        return None

    # Weather — enrich with a location from args when present (skips the variant
    # pool: the location already makes each phrase distinct).
    if "weather" in n:
        loc = _arg(args, "location", "city", "place", "query", "q")
        if loc:
            return _remember(f"Checking the weather in {loc}.")
        return _pick("weather")

    # Calendar / schedule.
    if any(k in n for k in ("calendar", "schedule", "event")):
        return _pick("calendar")

    # Web / fetch / browse — looking something up online.
    if any(k in n for k in ("web", "fetch", "browse", "url", "http", "google")):
        return _pick("web")

    # File search / grep / find.
    if any(k in n for k in ("search", "grep", "find")):
        return _pick("search")

    # Reading / listing files.
    if any(k in n for k in ("read", "file", "list", "glob", "cat")):
        return _pick("read")

    # Terminal / shell / bash / exec.
    if any(k in n for k in ("terminal", "bash", "shell", "exec", "run", "command")):
        return _pick("terminal")

    # Known-but-bland tools → a soft fallback so the silence isn't dead air.
    return _pick("fallback")
