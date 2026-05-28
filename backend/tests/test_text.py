from tests.conftest import FakeHermes, FakeTTS, build_client


def test_text_turn_returns_assistant_text_and_audio_url():
    hermes = FakeHermes(reply="hello back")
    tts = FakeTTS()
    client = build_client(hermes=hermes, stt=None, tts=tts)

    resp = client.post("/api/text", json={"text": "hi there"})

    assert resp.status_code == 200
    body = resp.json()
    assert body["user_text"] == "hi there"
    assert body["assistant_text"] == "hello back"
    assert body["session_id"] == "fake-session-1"
    assert body["audio_url"].startswith("/api/audio/")
    assert tts.calls == ["hello back"]
    assert hermes.calls == [("hi there", None)]


def test_text_turn_passes_session_id_to_hermes():
    hermes = FakeHermes()
    client = build_client(hermes=hermes, stt=None, tts=None)
    client.post("/api/text", json={"text": "first", "session_id": "abc"})
    client.post("/api/text", json={"text": "second", "session_id": "abc"})
    assert [c[1] for c in hermes.calls] == ["abc", "abc"]


def test_audio_url_serves_synthesized_bytes():
    client = build_client(hermes=FakeHermes(), stt=None, tts=FakeTTS())
    body = client.post("/api/text", json={"text": "hi"}).json()
    audio = client.get(body["audio_url"])
    assert audio.status_code == 200
    assert audio.content == b"FAKE"
    assert audio.headers["content-type"].startswith("audio/")


def test_text_turn_without_tts_returns_null_audio_url():
    client = build_client(hermes=FakeHermes(), stt=None, tts=None)
    body = client.post("/api/text", json={"text": "hi"}).json()
    assert body["audio_url"] is None
    assert body["assistant_text"] == "fake reply"


def test_token_required_when_configured(monkeypatch):
    monkeypatch.setenv("HERMES_VOICE_TOKEN", "s3cret")
    from app.config import reset_settings_cache
    reset_settings_cache()
    client = build_client(hermes=FakeHermes(), stt=None, tts=None)

    no_token = client.post("/api/text", json={"text": "hi"})
    assert no_token.status_code == 401

    ok = client.post(
        "/api/text",
        json={"text": "hi"},
        headers={"X-Hermes-Voice-Token": "s3cret"},
    )
    assert ok.status_code == 200
