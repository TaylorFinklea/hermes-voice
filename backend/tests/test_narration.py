"""Tests for the pure tool→spoken-filler mapping (app.narration.tool_narration).

Pure function: known names map to warm/casual/first-person phrases, args enrich
the salient ones, unknown/bland tools get a single soft fallback, and noisy /
internal tools return None so we stay quiet.
"""
from __future__ import annotations

import pytest

from app.narration import tool_narration


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
    assert phrase == "Checking the weather for you."


def test_weather_with_location_arg_enriches():
    phrase = tool_narration("get_weather", args={"location": "Boston"})
    assert phrase == "Checking the weather in Boston."


def test_calendar_narrates_checking_calendar():
    assert tool_narration("calendar") == "Checking your calendar."


@pytest.mark.parametrize("name", ["think", "todo_write", "update_plan", "memory_store"])
def test_noisy_internal_tools_return_none(name):
    assert tool_narration(name) is None


def test_empty_name_returns_none():
    assert tool_narration("") is None
    assert tool_narration(None) is None  # type: ignore[arg-type]


def test_unknown_tool_gets_soft_fallback():
    phrase = tool_narration("some_obscure_widget_tool")
    assert phrase == "Let me look into that."


def test_all_phrases_are_first_person_lowercase_starts_capitalized():
    # Sanity: every non-None phrase reads as a short spoken sentence.
    for name in ("terminal", "search", "web", "weather", "calendar", "mystery"):
        phrase = tool_narration(name)
        assert phrase is not None
        assert phrase[0].isupper()
        assert phrase.endswith(".")
