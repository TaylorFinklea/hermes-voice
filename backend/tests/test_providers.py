"""Provider factory tests — no network, no audio decode."""
from __future__ import annotations

from app.config import Settings
from app.hermes import HermesClient
from app.stt import make_stt
from app.tts import make_tts


def test_make_stt_prefers_openai_when_key_present():
    stt = make_stt(Settings(openai_key="x", groq_key=""))
    assert stt is not None
    assert stt.name == "openai_whisper"


def test_make_stt_falls_back_to_groq_when_only_groq_set():
    stt = make_stt(Settings(openai_key="", groq_key="g"))
    assert stt is not None
    assert stt.name == "groq_whisper"


def test_make_stt_uses_elevenlabs_when_only_eleven_set():
    stt = make_stt(Settings(elevenlabs_key="e"))
    assert stt is not None
    assert stt.name == "elevenlabs_scribe"


def test_make_stt_override_picks_elevenlabs_over_openai():
    stt = make_stt(Settings(
        stt_provider_override="elevenlabs",
        openai_key="o",
        elevenlabs_key="e",
    ))
    assert stt is not None
    assert stt.name == "elevenlabs_scribe"


def test_make_stt_returns_none_when_nothing_configured():
    # No keys, no local install assumed in CI; should be None.
    stt = make_stt(Settings(openai_key="", groq_key=""))
    # Result depends on whether faster-whisper happens to be installed.
    assert stt is None or stt.name == "local_whisper"


def test_make_stt_returns_mock_when_mock_mode():
    stt = make_stt(Settings(mock=True))
    assert stt is not None
    assert stt.name == "mock"


def test_make_tts_prefers_elevenlabs():
    tts = make_tts(Settings(elevenlabs_key="x", openai_key="y"))
    assert tts is not None
    assert tts.name == "elevenlabs"


def test_make_tts_falls_back_to_openai():
    tts = make_tts(Settings(elevenlabs_key="", openai_key="y"))
    assert tts is not None
    assert tts.name == "openai_tts"


def test_make_tts_returns_mock_when_mock_mode():
    tts = make_tts(Settings(mock=True))
    assert tts is not None
    assert tts.name == "mock"


def test_hermes_client_parse_handles_resume_notice():
    stdout = "↻ Resumed session abc (1 user message, 2 total messages)\r\nthe answer is 42\n"
    stderr = "\nsession_id: abc\n"
    reply = HermesClient._parse(stdout, stderr)
    assert reply.text == "the answer is 42"
    assert reply.session_id == "abc"


def test_hermes_client_parse_handles_fresh_session():
    stdout = "hello\n"
    stderr = "\nsession_id: new-1\n"
    reply = HermesClient._parse(stdout, stderr)
    assert reply.text == "hello"
    assert reply.session_id == "new-1"
