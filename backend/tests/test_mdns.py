"""Unit tests for the Bonjour/mDNS advertiser.

Only the pure logic is exercised — the advertiser's real network ops run inside
the FastAPI lifespan, which TestClient doesn't fire, so nothing here touches
multicast.
"""
from app import mdns


def test_in_cgnat_classifies_tailscale_range():
    assert mdns._in_cgnat("100.64.0.1")
    assert mdns._in_cgnat("100.112.34.59")   # a real Tailscale addr on this host
    assert mdns._in_cgnat("100.127.255.255")
    assert not mdns._in_cgnat("100.63.0.1")  # just below 100.64/10
    assert not mdns._in_cgnat("100.128.0.1")  # just above
    assert not mdns._in_cgnat("192.168.1.5")
    assert not mdns._in_cgnat("10.0.0.1")
    assert not mdns._in_cgnat("not.an.ip")


async def test_stop_mdns_none_is_noop():
    # Must not raise when advertising was skipped (start returned None).
    await mdns.stop_mdns(None)


async def test_start_mdns_skips_without_lan(monkeypatch):
    # No LAN IPv4 → returns None and never touches the network.
    monkeypatch.setattr(mdns, "_primary_lan_ipv4", lambda: None)
    assert await mdns.start_mdns(port=8765, scheme="http") is None
