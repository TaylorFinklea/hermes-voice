"""Make an assistant reply speakable: strip markdown/code formatting so TTS
reads natural prose instead of literal "##", asterisks, backticks, fenced code
blocks, and ASCII tables.

This is a deterministic backstop applied to the SPOKEN copy only — the displayed
transcript keeps the original markdown. It runs on every harness's reply at the
TTS chokepoint, so it is independent of whether the model was told to avoid
markdown (the voice system prompt) and of session/resume state. The voice system
prompt is the primary lever for *concise* output; this guarantees *clean* output
even when the model slips.

Pure `str -> str`, no dependencies, idempotent:
`make_speakable(make_speakable(x)) == make_speakable(x)`.
"""
from __future__ import annotations

import re

# Spoken in place of a fenced code block. Parens are not vocalized by TTS, so
# this reads as "code shown on screen" rather than "open paren …".
CODE_PLACEHOLDER = "(code shown on screen)"

_FENCE_RE = re.compile(r"^\s*(?:`{3,}|~{3,})")
_HEADING_RE = re.compile(r"^\s*#{1,6}\s+")
_BLOCKQUOTE_RE = re.compile(r"^\s*>\s?")
_BULLET_RE = re.compile(r"^\s*[-*+]\s+")
_NUMBERED_RE = re.compile(r"^\s*\d+[.)]\s+")
# A horizontal rule: a line of 3+ of the same -, *, or _ (with optional spaces).
_HR_RE = re.compile(r"^\s*([-*_])(?:\s*\1){2,}\s*$")
# A markdown table separator row: pipes around runs of - and optional : .
_TABLE_SEP_RE = re.compile(r"^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)+\|?\s*$")

_IMAGE_RE = re.compile(r"!\[([^\]]*)\]\([^)]*\)")
_LINK_RE = re.compile(r"\[([^\]]+)\]\([^)]*\)")
_AUTOLINK_RE = re.compile(r"<((?:https?://|mailto:)[^>]+)>")
_INLINE_CODE_RE = re.compile(r"`+([^`]+)`+")
_BOLD_STAR_RE = re.compile(r"\*\*([^*]+)\*\*")
_BOLD_UNDER_RE = re.compile(r"__([^_]+)__")
_STRIKE_RE = re.compile(r"~~([^~]+)~~")
_ITALIC_STAR_RE = re.compile(r"(?<![\w*])\*([^*\n]+)\*(?![\w*])")
_ITALIC_UNDER_RE = re.compile(r"(?<![\w_])_([^_\n]+)_(?![\w_])")

_MULTI_BLANK_RE = re.compile(r"\n{3,}")


def _strip_inline(line: str) -> str:
    """Remove inline markdown spans, keeping the inner text."""
    line = _IMAGE_RE.sub(r"\1", line)
    line = _LINK_RE.sub(r"\1", line)
    line = _AUTOLINK_RE.sub(r"\1", line)
    line = _INLINE_CODE_RE.sub(r"\1", line)
    line = _BOLD_STAR_RE.sub(r"\1", line)
    line = _BOLD_UNDER_RE.sub(r"\1", line)
    line = _STRIKE_RE.sub(r"\1", line)
    line = _ITALIC_STAR_RE.sub(r"\1", line)
    line = _ITALIC_UNDER_RE.sub(r"\1", line)
    return line


def _drop_code_fences(lines: list[str]) -> list[str]:
    """Replace each *closed* fenced code block with a spoken placeholder.

    Only a fence with a matching closer before EOF is treated as a code block.
    An unclosed fence is left as ordinary text (its marker line dropped), so a
    malformed reply never loses everything after a stray ``` — the exact failure
    a naive "drop to end of string" would cause.
    """
    out: list[str] = []
    i = 0
    n = len(lines)
    while i < n:
        if not _FENCE_RE.match(lines[i]):
            out.append(lines[i])
            i += 1
            continue
        # Opening fence: look for a closing fence on a later line.
        j = i + 1
        while j < n and not _FENCE_RE.match(lines[j]):
            j += 1
        if j < n:  # closed block: collapse to one placeholder
            out.append(CODE_PLACEHOLDER)
            i = j + 1
        else:  # unclosed: drop only this marker line, keep the rest as prose
            i += 1
    return out


def make_speakable(text: str) -> str:
    """Strip markdown/code formatting from `text` for text-to-speech."""
    if not text or not text.strip():
        return text

    lines = _drop_code_fences(text.split("\n"))
    cleaned: list[str] = []
    for line in lines:
        if _HR_RE.match(line) or _TABLE_SEP_RE.match(line):
            continue
        line = _HEADING_RE.sub("", line)
        line = _BLOCKQUOTE_RE.sub("", line)
        line = _BULLET_RE.sub("", line)
        line = _NUMBERED_RE.sub("", line)
        # Table data row -> comma-separated clause so TTS pauses between cells.
        if line.count("|") >= 2:
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            line = ", ".join(c for c in cells if c)
        cleaned.append(_strip_inline(line))

    out = _MULTI_BLANK_RE.sub("\n\n", "\n".join(cleaned))
    return out.strip()
