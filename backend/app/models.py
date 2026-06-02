"""Request/response shapes shared by the API."""
from __future__ import annotations

from pydantic import BaseModel, Field  # noqa: F401  (Field used below)


class TextRequest(BaseModel):
    text: str = Field(..., min_length=1, max_length=4000)
    session_id: str | None = None
    voice_id: str | None = Field(default=None, max_length=80, pattern=r"^[A-Za-z0-9_-]*$")
    # "none" → skip server TTS (the client synthesizes the reply on-device, e.g.
    # Kokoro). Omitted / "server" → synthesize as usual. This is the hook that
    # lets the phone own voice I/O and treat the backend as a text-only brain.
    tts: str | None = Field(default=None, pattern=r"^(none|server)$")
    # Which agent backs this turn (hermes / claude / codex / opencode). Omitted
    # → the backend's default harness. Mirrors the per-turn `tts` switch.
    harness: str | None = Field(default=None, max_length=40, pattern=r"^[a-z0-9_-]*$")


class ToolCallSummary(BaseModel):
    name: str
    preview: str
    ok: bool


class TurnResponse(BaseModel):
    session_id: str
    user_text: str
    assistant_text: str
    audio_url: str | None = None
    tool_calls: list[ToolCallSummary] = Field(default_factory=list)


class SessionListItem(BaseModel):
    session_id: str
    source: str
    started_at: float
    message_count: int
    tool_call_count: int
    preview: str


class HistoryToolCall(BaseModel):
    name: str
    arguments_preview: str
    ok: bool | None = None


class HistoryMessage(BaseModel):
    role: str  # "user" | "assistant" | "tool"
    text: str
    timestamp: float
    tool_name: str | None = None
    tool_calls: list[HistoryToolCall] = Field(default_factory=list)


class SessionDetailResponse(BaseModel):
    session_id: str
    source: str
    started_at: float
    title: str | None
    messages: list[HistoryMessage]


class ReplayRequest(BaseModel):
    text: str = Field(..., min_length=1, max_length=4000)
    voice_id: str | None = Field(default=None, max_length=80, pattern=r"^[A-Za-z0-9_-]*$")


class ReplayResponse(BaseModel):
    audio_url: str | None


class VoiceItem(BaseModel):
    """One selectable TTS voice (ElevenLabs catalog)."""
    voice_id: str
    name: str
    category: str | None = None


class HarnessItem(BaseModel):
    """One selectable agent backend (Hermes, Claude Code, Codex, OpenCode)."""
    id: str
    name: str
    available: bool


class HealthResponse(BaseModel):
    status: str
    mock: bool
    hermes: dict
    stt: dict
    tts: dict
    scheme: str = "http"


# ───── Schedules (recurring messages) ─────


class ScheduleResponse(BaseModel):
    """One schedule, as returned by /api/schedules."""
    id: str
    cadence_seconds: int
    prompt: str
    display_name: str | None = None
    created_at: float
    last_fired_at: float | None = None
    next_fire_at: float
    enabled: bool
    consecutive_fails: int = 0
    source: str = "ios"


class ScheduleCreateRequest(BaseModel):
    cadence_seconds: int = Field(..., ge=60, description="Min 60s per schedules-spec")
    prompt: str = Field(..., min_length=1, max_length=2000)
    display_name: str | None = Field(default=None, max_length=80)


class ScheduleUpdateRequest(BaseModel):
    """All fields optional — PATCH semantics. Set enabled=false to pause."""
    cadence_seconds: int | None = Field(default=None, ge=60)
    prompt: str | None = Field(default=None, min_length=1, max_length=2000)
    display_name: str | None = Field(default=None, max_length=80)
    enabled: bool | None = None


# ───── Push notification device registration ─────


class DeviceRegisterRequest(BaseModel):
    token: str = Field(..., min_length=8, max_length=256, pattern=r"^[0-9a-fA-F]{64}$")
    platform: str = Field(default="ios", pattern="^(ios|watchos)$")
    bundle_id: str = Field(..., min_length=1, max_length=200)
    environment: str = Field(default="sandbox", pattern="^(sandbox|production)$")


class DeviceResponse(BaseModel):
    token: str
    platform: str
    bundle_id: str
    environment: str
    registered_at: float
    last_seen_at: float
