"""APNs push delivery for scheduled-fire notifications.

When a schedule completes a Hermes turn, we push the reply text to all
registered iOS devices. iOS:
- Shows the notification with the bundled hermes-chime sound while locked
  or backgrounded.
- Suppresses the banner and routes into the foreground chime + auto-play
  path when the app is open (handled iOS-side, not here).

The whole subsystem is opt-in: if `APNS_KEY_PATH` is empty or the .p8 file
doesn't exist, `send_push` is a silent no-op. This lets Phase B ship
without the APNs setup blocking everything else.
"""
from __future__ import annotations

import logging
from pathlib import Path

from .config import Settings
from .schedules import Device, delete_device, list_devices

logger = logging.getLogger("hermes_voice.push")

# iOS will reject notification bodies longer than ~250 chars in display;
# we truncate to a hard ceiling so APNs accepts the payload (4KB total
# limit minus headers).
MAX_BODY_CHARS = 300


def _build_payload(body: str, schedule_id: str, session_id: str) -> dict:
    """Build the alert payload + custom data the iOS app reads on tap."""
    return {
        "aps": {
            "alert": {
                "title": "Hermes",
                "body": body[:MAX_BODY_CHARS],
            },
            "sound": "hermes-chime.caf",
            "mutable-content": 1,
            "thread-id": schedule_id,  # iOS groups same-schedule notifs
        },
        # Custom keys the iOS notification delegate uses to route the tap
        # back into the right session for foreground auto-play.
        "schedule_id": schedule_id,
        "session_id": session_id,
    }


def is_configured(settings: Settings) -> bool:
    """True if push delivery has a usable APNs key on disk."""
    if not settings.apns_key_path or not settings.apns_key_id or not settings.apns_team_id:
        return False
    return Path(settings.apns_key_path).exists()


async def send_push(
    settings: Settings,
    *,
    body: str,
    schedule_id: str,
    session_id: str,
) -> int:
    """Send to all registered devices. Returns count delivered.

    Silently no-ops if APNs isn't configured. Dead-token cleanup happens
    inline so the next fire doesn't re-attempt invalid devices.
    """
    if not is_configured(settings):
        logger.debug("APNs not configured; skipping push (schedule=%s)", schedule_id)
        return 0

    devices = await list_devices()
    if not devices:
        return 0

    # Import inline so the dep is only required at first push, not at import.
    # Means test runs without aioapns installed still work for the non-push paths.
    try:
        from aioapns import APNs, NotificationRequest
    except ImportError:
        logger.warning("aioapns not installed; cannot send push")
        return 0

    # aioapns hands `key` straight to jwt.encode(), which expects the PEM
    # CONTENTS — not a file path. Read the .p8 once here. (Passing the path
    # produces a misleading "Unable to load PEM file / MalformedFraming".)
    try:
        key_pem = Path(settings.apns_key_path).read_text()
    except OSError as e:
        logger.warning("could not read APNs key at %s: %s", settings.apns_key_path, e)
        return 0

    payload = _build_payload(body, schedule_id, session_id)
    sent = 0

    # We make one APNs client per environment present in our device list
    # because Apple has separate sandbox + production endpoints. Almost
    # always there's just one in practice.
    by_env: dict[str, list[Device]] = {}
    for d in devices:
        by_env.setdefault(d.environment, []).append(d)

    for env, env_devices in by_env.items():
        use_sandbox = env == "sandbox" or settings.apns_use_sandbox
        try:
            client = APNs(
                key=key_pem,
                key_id=settings.apns_key_id,
                team_id=settings.apns_team_id,
                topic=settings.apns_bundle_id,
                use_sandbox=use_sandbox,
            )
        except Exception as e:
            logger.warning("APNs client init failed (env=%s): %s", env, e)
            continue

        for device in env_devices:
            req = NotificationRequest(
                device_token=device.token,
                message=payload,
            )
            try:
                response = await client.send_notification(req)
                if response.is_successful:
                    sent += 1
                else:
                    desc = (response.description or "").lower()
                    # Drop tokens APNs reports as bad/unregistered so we
                    # don't keep trying on the next fire.
                    if any(k in desc for k in ("unregistered", "badtoken", "bad device token")):
                        await delete_device(device.token)
                        logger.info(
                            "dropped invalid APNs token=%s… reason=%s",
                            device.token[:8], response.description,
                        )
                    else:
                        logger.warning(
                            "push failed token=%s… reason=%s",
                            device.token[:8], response.description,
                        )
            except Exception as e:
                logger.warning("push exception token=%s… err=%s", device.token[:8], e)

    return sent
