"""Environment-driven configuration.

All knobs live here so providers and routes stay env-var-free.
"""
from __future__ import annotations

import os
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path

from dotenv import load_dotenv

# Auto-load backend/.env once at import. Lets `uv run python -m app` pick up
# keys without the user having to `source .env` manually.
# override=False so explicit shell env still wins.
_ENV_PATH = Path(__file__).resolve().parent.parent / ".env"
if _ENV_PATH.exists():
    load_dotenv(_ENV_PATH, override=False)


def _env(*names: str, default: str = "") -> str:
    for n in names:
        v = os.environ.get(n)
        if v:
            return v
    return default


def _bool(name: str, default: bool = False) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


@dataclass(frozen=True)
class Settings:
    host: str = "127.0.0.1"
    port: int = 8765
    mock: bool = False
    auth_token: str = ""
    ssl_certfile: str = ""
    ssl_keyfile: str = ""

    # Bonjour/mDNS LAN advertisement (zero-config discovery by the iOS app).
    bonjour_enabled: bool = True
    # Canonical host to advertise in the Bonjour TXT record (e.g. a Tailscale
    # MagicDNS name like "scadrial.tailXXXX.ts.net"). When set, the iOS client
    # builds its base URL from THIS host so an HTTPS Tailscale cert validates —
    # a raw .local / LAN-IP host wouldn't. Empty → advertise the LAN IP, which
    # is correct for a plain-HTTP backend on the LAN.
    public_host: str = ""

    hermes_bin: str = "hermes"
    # Per-turn ceiling. Resuming a long Claude session replays its whole
    # transcript before the first reply, so this matches the iOS client's
    # 300s request timeout rather than cutting off big-session resumes early.
    hermes_timeout: int = 300
    hermes_extra_args: tuple[str, ...] = field(default_factory=tuple)

    # Multi-harness: which agent backs a turn when the request doesn't name one,
    # and where/how the coding harnesses (claude/codex/opencode) run. Hermes
    # ignores workspace/sandbox; the others are cwd-scoped coding agents that run
    # in a shared workspace under a sandbox.
    default_harness: str = "hermes"
    harness_workspace_dir: str = ""
    harness_sandbox: str = "workspace-write"
    # Slugs (working-dir fragments) to hide from the Claude session picker — e.g.
    # throwaway "ClaudeProbe" sessions a usage-probe tool (codexbar) creates.
    claude_session_exclude: tuple[str, ...] = ("ClaudeProbe",)

    stt_provider_override: str = ""
    openai_key: str = ""
    groq_key: str = ""
    local_whisper_model: str = "base.en"
    local_whisper_device: str = "auto"

    tts_provider_override: str = ""
    elevenlabs_key: str = ""
    elevenlabs_voice_id: str = "nPczCjzI2devNBz1zQrb"
    elevenlabs_model: str = "eleven_turbo_v2_5"
    openai_tts_model: str = "tts-1"
    openai_tts_voice: str = "onyx"
    piper_voice_path: str = ""

    # APNs (Phase B — scheduled-fire push notifications). All optional; if the
    # key path is empty, push silently no-ops.
    apns_key_path: str = ""        # absolute path to the .p8 from Apple Dev
    apns_key_id: str = ""          # 10-char Key ID
    apns_team_id: str = ""         # 10-char Team ID
    apns_bundle_id: str = "dev.finklea.harnessvoice"
    apns_use_sandbox: bool = True  # TestFlight + dev devices use sandbox


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    extra = _env("HERMES_EXTRA_ARGS").split()
    return Settings(
        host=_env("HERMES_VOICE_HOST", default="127.0.0.1"),
        port=int(_env("HERMES_VOICE_PORT", default="8765")),
        mock=_bool("HERMES_VOICE_MOCK", default=False),
        auth_token=_env("HERMES_VOICE_TOKEN"),
        ssl_certfile=_env("HERMES_VOICE_CERT"),
        ssl_keyfile=_env("HERMES_VOICE_KEY"),
        bonjour_enabled=_bool("HERMES_VOICE_BONJOUR", default=True),
        public_host=_env("HERMES_VOICE_PUBLIC_HOST"),
        hermes_bin=_env("HERMES_BIN", default="hermes"),
        hermes_timeout=int(_env("HERMES_TIMEOUT_SECONDS", default="180")),
        hermes_extra_args=tuple(extra),
        default_harness=_env("HARNESS_DEFAULT", default="hermes"),
        harness_workspace_dir=_env(
            "HARNESS_WORKSPACE_DIR",
            default=str(Path.home() / ".harness-voice" / "workspace"),
        ),
        harness_sandbox=_env("HARNESS_SANDBOX", default="workspace-write"),
        claude_session_exclude=tuple(
            s.strip()
            for s in _env("CLAUDE_SESSION_EXCLUDE", default="ClaudeProbe").split(",")
            if s.strip()
        ),
        stt_provider_override=_env("STT_PROVIDER"),
        openai_key=_env("OPENAI_API_KEY", "VOICE_TOOLS_OPENAI_KEY"),
        groq_key=_env("GROQ_API_KEY"),
        local_whisper_model=_env("LOCAL_WHISPER_MODEL", default="base.en"),
        local_whisper_device=_env("LOCAL_WHISPER_DEVICE", default="auto"),
        tts_provider_override=_env("TTS_PROVIDER"),
        elevenlabs_key=_env("ELEVENLABS_API_KEY"),
        elevenlabs_voice_id=_env(
            "ELEVENLABS_VOICE_ID", default="nPczCjzI2devNBz1zQrb"
        ),
        elevenlabs_model=_env("ELEVENLABS_MODEL", default="eleven_turbo_v2_5"),
        openai_tts_model=_env("OPENAI_TTS_MODEL", default="tts-1"),
        openai_tts_voice=_env("OPENAI_TTS_VOICE", default="onyx"),
        piper_voice_path=_env("PIPER_VOICE_PATH"),
        apns_key_path=_env("APNS_KEY_PATH"),
        apns_key_id=_env("APNS_KEY_ID"),
        apns_team_id=_env("APNS_TEAM_ID"),
        apns_bundle_id=_env("APNS_BUNDLE_ID", default="dev.finklea.harnessvoice"),
        apns_use_sandbox=_bool("APNS_USE_SANDBOX", default=True),
    )


def reset_settings_cache() -> None:
    """Test helper — env changes between tests need this."""
    get_settings.cache_clear()
