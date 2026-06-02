"""Advertise the backend over Bonjour/mDNS for zero-config LAN discovery.

The iOS app browses for `_harness-voice._tcp` on the local network and fills in
the backend URL automatically. mDNS is link-local only — it does NOT traverse
Tailscale — so this helps the same-Wi-Fi case; the remote path stays a
manually-entered Tailscale MagicDNS hostname.

Everything here is best-effort: a headless / no-LAN host, a name collision, or a
missing `zeroconf` install all degrade to "don't advertise", never a crash.
The `zeroconf` import is lazy (inside `start_mdns`) so importing this module is
always safe even if the optional dep isn't present — same pattern as `push.py`.
"""
from __future__ import annotations

import logging
import socket

logger = logging.getLogger("hermes_voice")

SERVICE_TYPE = "_harness-voice._tcp.local."


def _in_cgnat(ip: str) -> bool:
    """True for 100.64.0.0/10 — the CGNAT range Tailscale assigns."""
    try:
        a, b = (int(x) for x in ip.split(".")[:2])
    except ValueError:
        return False
    return a == 100 and 64 <= b <= 127


def _primary_lan_ipv4() -> str | None:
    """The LAN IPv4 to advertise on a multi-homed host.

    Asks the kernel routing table which source IP it would use to reach a
    routable destination. No packet is sent (UDP `connect` just sets the default
    peer), but it must have a default route to answer. On a Tailscale host this
    returns the real LAN address (e.g. 192.168.x / 10.x), NOT the 100.64/10
    CGNAT one — unlike `gethostbyname(gethostname())`, which returns the
    Tailscale address and would advertise an A record LAN clients can't reach.
    """
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        # 192.0.2.0/24 is TEST-NET-1 (RFC 5737): guaranteed unrouted, unreached.
        s.connect(("192.0.2.1", 9))
        ip = s.getsockname()[0]
    except OSError:
        return None
    finally:
        s.close()
    if ip.startswith("127.") or _in_cgnat(ip):
        return None
    return ip


async def start_mdns(
    *,
    port: int,
    scheme: str,
    path: str = "/",
    public_host: str = "",
    instance_name: str = "Hermes Voice",
):
    """Register the Bonjour service. Returns an opaque handle for `stop_mdns`,
    or None if advertising was skipped (no LAN, conflict, or zeroconf missing).

    `public_host`, when non-empty, is advertised in the TXT record as `host` so
    the iOS client can build a URL whose hostname matches the TLS cert (e.g. a
    Tailscale MagicDNS name); otherwise clients use the resolved LAN host.
    """
    try:
        from zeroconf import IPVersion, NonUniqueNameException, ServiceInfo
        from zeroconf.asyncio import AsyncZeroconf
    except ImportError:
        logger.info("mDNS: zeroconf not installed; skipping Bonjour advertisement")
        return None

    ip = _primary_lan_ipv4()
    if ip is None:
        logger.info("mDNS: no LAN IPv4 found; skipping Bonjour advertisement")
        return None

    hostname = socket.gethostname().split(".")[0]
    properties: dict[str, str] = {"version": "1", "scheme": scheme, "path": path}
    if public_host:
        properties["host"] = public_host

    info = ServiceInfo(
        SERVICE_TYPE,
        name=f"{instance_name}.{SERVICE_TYPE}",
        # Explicit — zeroconf does NOT auto-fill the A record. Pass only the LAN
        # IP so resolution never hands clients the Tailscale address.
        parsed_addresses=[ip],
        port=port,
        properties=properties,
        server=f"hermes-{hostname}.local.",
    )

    aiozc = AsyncZeroconf(ip_version=IPVersion.V4Only)
    try:
        # Awaits conflict-probe + broadcast. allow_name_change dodges collisions.
        await aiozc.async_register_service(info, allow_name_change=True)
    except NonUniqueNameException as e:
        logger.warning("mDNS: name conflict, not advertising: %s", e)
        await aiozc.async_close()
        return None
    except OSError as e:
        logger.warning("mDNS: registration failed (network unavailable?): %s", e)
        await aiozc.async_close()
        return None

    logger.info("mDNS: advertising %s at %s://%s:%d%s", SERVICE_TYPE, scheme, ip, port, path)
    return (aiozc, info)


async def stop_mdns(state) -> None:
    """Unregister (sends mDNS 'goodbye') and release the multicast socket."""
    if state is None:
        return
    aiozc, info = state
    try:
        await aiozc.async_unregister_service(info)
    finally:
        await aiozc.async_close()
