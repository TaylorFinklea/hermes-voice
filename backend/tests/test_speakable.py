"""Tests for the markdown-to-speech sanitizer (app.speakable.make_speakable).

Cases live in tests/fixtures/speakable_cases.json so the same corpus can guard
the iOS mirror (LocalSpeaker.makeSpeakable) against drift once an iOS test
target exists.
"""
from __future__ import annotations

import json
from pathlib import Path

import pytest

from app.speakable import CODE_PLACEHOLDER, make_speakable

_FIXTURE = Path(__file__).parent / "fixtures" / "speakable_cases.json"
_CASES = json.loads(_FIXTURE.read_text(encoding="utf-8"))


@pytest.mark.parametrize("case", _CASES, ids=[c["name"] for c in _CASES])
def test_make_speakable_matches_expected(case):
    assert make_speakable(case["input"]) == case["expected"]


@pytest.mark.parametrize("case", _CASES, ids=[c["name"] for c in _CASES])
def test_make_speakable_is_idempotent(case):
    once = make_speakable(case["input"])
    assert make_speakable(once) == once


def test_empty_and_whitespace_passthrough():
    assert make_speakable("") == ""
    assert make_speakable("   \n  ") == "   \n  "


def test_unclosed_fence_never_swallows_tail():
    # The exact regression a naive drop-to-EOF would cause: a stray opening
    # fence must not erase everything after it.
    out = make_speakable("Important note\n```\nleftover")
    assert "Important note" in out
    assert "leftover" in out
    assert CODE_PLACEHOLDER not in out
