"""Tests for the pure tool→spoken-filler mapping (app.narration.tool_narration).

Pure function: known names map to warm/casual/first-person phrases, args enrich
the salient ones, unknown/bland tools get a single soft fallback, and noisy /
internal tools return None so we stay quiet.
"""
from __future__ import annotations

from itertools import pairwise

import pytest

from app.narration import NARRATION_PHRASES, tool_narration


@pytest.mark.parametrize(
    "name",
    ["terminal", "bash", "shell", "exec", "run_command"],
)
def test_terminal_family_narrates_running(name):
    phrase = tool_narration(name, preview="$ echo hi")
    assert phrase and "run" in phrase.lower()


@pytest.mark.parametrize("name", ["search", "grep", "find_files"])
def test_search_family_narrates_searching_files(name):
    phrase = tool_narration(name)
    assert phrase and "search" in phrase.lower()


@pytest.mark.parametrize("name", ["web", "fetch", "web_search", "browse"])
def test_web_family_narrates_looking_up_online(name):
    phrase = tool_narration(name)
    assert phrase and "online" in phrase.lower()


def test_weather_without_args_is_generic():
    phrase = tool_narration("weather")
    assert phrase in NARRATION_PHRASES["weather"]


def test_weather_with_location_arg_enriches():
    phrase = tool_narration("get_weather", args={"location": "Boston"})
    assert phrase == "Checking the weather in Boston."


def test_calendar_narrates_checking_calendar():
    assert tool_narration("calendar") in NARRATION_PHRASES["calendar"]


@pytest.mark.parametrize("name", ["think", "todo_write", "update_plan", "memory_store"])
def test_noisy_internal_tools_return_none(name):
    assert tool_narration(name) is None


def test_empty_name_returns_none():
    assert tool_narration("") is None
    assert tool_narration(None) is None  # type: ignore[arg-type]


def test_unknown_tool_gets_soft_fallback():
    phrase = tool_narration("some_obscure_widget_tool")
    assert phrase in NARRATION_PHRASES["fallback"]


def test_repeated_same_family_calls_never_repeat_consecutively():
    # The user's complaint: a run of same-family tool calls said one identical
    # phrase. Every adjacent pair must now differ.
    phrases = [tool_narration("search") for _ in range(20)]
    assert all(a != b for a, b in pairwise(phrases))
    # And it actually uses the variety, not just two alternating phrases.
    assert len(set(phrases)) >= 3


def test_every_family_phrase_reads_as_a_spoken_sentence():
    for variants in NARRATION_PHRASES.values():
        assert len(variants) >= 5  # 5-10 variants per family
        for phrase in variants:
            assert phrase[0].isupper()
            assert phrase.endswith(".")


def test_all_phrases_are_first_person_lowercase_starts_capitalized():
    # Sanity: every non-None phrase reads as a short spoken sentence.
    for name in ("terminal", "search", "web", "weather", "calendar", "mystery"):
        phrase = tool_narration(name)
        assert phrase is not None
        assert phrase[0].isupper()
        assert phrase.endswith(".")
