"""Per-turn harness dispatch (the `harness` request field) + /api/harnesses."""
from tests.conftest import FakeHermes, build_client


def test_default_harness_used_when_omitted():
    hermes = FakeHermes(reply="default reply")
    client = build_client(hermes=hermes, stt=None, tts=None)
    resp = client.post("/api/text", json={"text": "hi"})
    assert resp.status_code == 200
    assert resp.json()["assistant_text"] == "default reply"
    assert hermes.calls == [("hi", None)]


def test_explicit_hermes_harness_routes_to_hermes():
    hermes = FakeHermes(reply="hermes reply")
    client = build_client(hermes=hermes, stt=None, tts=None)
    resp = client.post("/api/text", json={"text": "hi", "harness": "hermes"})
    assert resp.status_code == 200
    assert resp.json()["assistant_text"] == "hermes reply"


def test_unknown_harness_returns_422():
    client = build_client(hermes=FakeHermes(), stt=None, tts=None)
    resp = client.post("/api/text", json={"text": "hi", "harness": "bogus"})
    assert resp.status_code == 422
    assert "unknown harness" in resp.text


def test_unknown_harness_on_stream_returns_422_before_streaming():
    # The stream endpoint must validate the harness BEFORE the StreamingResponse
    # starts, so the client sees a clean 422 rather than a 200 that dies mid-body.
    client = build_client(hermes=FakeHermes(), stt=None, tts=None)
    resp = client.post("/api/text/stream", json={"text": "hi", "harness": "bogus"})
    assert resp.status_code == 422


def test_list_harnesses_reports_registered_backends():
    client = build_client(hermes=FakeHermes(), stt=None, tts=None)
    resp = client.get("/api/harnesses")
    assert resp.status_code == 200
    items = resp.json()
    ids = {it["id"]: it for it in items}
    assert "hermes" in ids
    assert ids["hermes"]["name"] == "Hermes"
    assert ids["hermes"]["available"] is True


def test_invalid_harness_pattern_rejected_by_model():
    # Pydantic pattern guards the field (no spaces / uppercase / punctuation).
    client = build_client(hermes=FakeHermes(), stt=None, tts=None)
    resp = client.post("/api/text", json={"text": "hi", "harness": "Bad Name!"})
    assert resp.status_code == 422
