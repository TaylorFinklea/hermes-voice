"""Security posture: /health detail gating + fail-closed non-loopback bind."""
import pytest

from app.config import Settings
from app.main import _is_loopback_host, assert_safe_bind
from tests.conftest import FakeHermes, build_client


def test_health_without_configured_token_returns_details():
    # No token configured (loopback dev) → nothing to gate on, so the
    # reachability check still surfaces the diagnostics details.
    client = build_client(hermes=FakeHermes(), stt=None, tts=None)
    body = client.get("/health").json()
    assert body["status"] == "ok"
    assert "scheme" in body
    assert body["hermes"] != {}


def test_health_with_token_includes_details(monkeypatch):
    monkeypatch.setenv("HERMES_VOICE_TOKEN", "s3cret")
    from app.config import reset_settings_cache

    reset_settings_cache()
    try:
        client = build_client(hermes=FakeHermes(), stt=None, tts=None)
        # Wrong/missing token → minimal.
        assert client.get("/health").json()["hermes"] == {}
        # Correct token → details disclosed.
        body = client.get(
            "/health", headers={"X-Hermes-Voice-Token": "s3cret"}
        ).json()
        assert body["hermes"] != {}
    finally:
        reset_settings_cache()


@pytest.mark.parametrize(
    "host,loopback",
    [
        ("127.0.0.1", True),
        ("localhost", True),
        ("::1", True),
        ("127.0.0.5", True),
        ("0.0.0.0", False),
        ("::", False),
        ("100.64.1.2", False),
        ("192.168.1.10", False),
    ],
)
def test_is_loopback_host(host, loopback):
    assert _is_loopback_host(host) is loopback


def test_assert_safe_bind_refuses_exposed_without_token():
    with pytest.raises(RuntimeError, match="refusing to start"):
        assert_safe_bind(Settings(host="0.0.0.0", auth_token=""))


def test_assert_safe_bind_allows_loopback_without_token():
    assert assert_safe_bind(Settings(host="127.0.0.1", auth_token="")) is None


def test_assert_safe_bind_allows_exposed_with_token():
    assert assert_safe_bind(Settings(host="0.0.0.0", auth_token="tok")) is None
