from tests.conftest import FakeHermes, FakeTTS, build_client


def test_health_reports_provider_status():
    client = build_client(hermes=FakeHermes(), stt=None, tts=FakeTTS())
    resp = client.get("/health")
    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "ok"
    assert body["hermes"]["available"] is True
    assert body["stt"]["name"] == "none"
    assert body["tts"]["name"] == "fake_tts"
