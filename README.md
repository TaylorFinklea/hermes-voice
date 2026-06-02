# Harness Voice

Voice-native iPhone front-end for a local coding agent (Hermes, Claude Code, Codex, or OpenCode). Push-to-talk on the phone, Hermes does the actual operating on the Mac, audio answer plays back. Built to replace the rough Telegram-voice experience with something dedicated.

## Architecture

```
┌──────────────┐   audio (m4a)   ┌──────────────────┐   subprocess   ┌───────────┐
│ iOS app      │ ──────────────▶ │ FastAPI backend  │ ─────────────▶ │ hermes CLI│
│ (SwiftUI)    │                 │  /api/audio      │                │ on macOS  │
│              │ ◀────────────── │  /api/text       │ ◀───────────── │           │
└──────────────┘  TurnResponse   │  STT + TTS layer │   stdout/      └───────────┘
                  (text + URL)   └──────────────────┘   session_id
                                          │
                       ┌──────────────────┼──────────────────┐
                       ▼                  ▼                  ▼
                 STT providers       TTS providers      Audio cache
                 (OpenAI, Groq,      (ElevenLabs,       (tmp dir,
                  faster-whisper)    OpenAI, Piper)     served by id)
```

A turn is one round trip: iPhone records → POSTs audio → backend STT → `hermes chat -Q -q <text>` (with `--resume <id>` on follow-ups so Hermes keeps tool/context state) → backend TTS → iPhone plays mp3/wav.

## What's in the box

- **`backend/`** — FastAPI service. Provider abstractions for STT (OpenAI / Groq / local faster-whisper / mock) and TTS (ElevenLabs / OpenAI / local Piper / mock). 18 unit tests with fake providers.
- **`ios/HermesVoice/`** — SwiftUI app, regenerable via XcodeGen from `project.yml`. Push-to-talk that supports both *hold-to-talk* and *tap-to-latch*. Always-visible text input fallback.

## Quick start

### 1. Backend

```bash
cd backend
uv sync --extra dev
cp .env.example .env          # edit if you have keys; otherwise skip
uv run python -m app          # serves on http://127.0.0.1:8765
```

With **no env vars set**, the backend auto-engages mock mode — `/health` reports it, `/api/text` returns canned replies, `/api/audio` is disabled until you wire up an STT provider. This lets you iterate on the iOS app without burning API calls.

Smoke test it:

```bash
curl -s http://127.0.0.1:8765/health | jq
curl -s -X POST http://127.0.0.1:8765/api/text \
  -H 'content-type: application/json' \
  -d '{"text":"hello hermes"}' | jq
```

### 2. iOS app

```bash
cd ios/HermesVoice
xcodegen generate            # regenerates HermesVoice.xcodeproj from project.yml
open HermesVoice.xcodeproj
```

Then in Xcode:
1. Select a development team in *Signing & Capabilities* (your personal team is fine).
2. Pick a simulator (or your iPhone) and **Run**.
3. First launch on a real phone: tap the gear icon and set the backend URL to your Mac's reachable address (Tailscale IP recommended, e.g. `http://100.64.x.y:8765`).
4. Tap *Ping /health* in Settings to verify connectivity.

### 3. Reach your Mac from your phone

You have three options, in order of preference:

1. **Tailscale** (best). Install Tailscale on both, run the backend with `HERMES_VOICE_HOST=0.0.0.0`, use your Mac's Tailscale IP in the iOS Settings screen.
2. **LAN**: same Wi-Fi, find your Mac's local IP (`ipconfig getifaddr en0`), bind to `0.0.0.0`.
3. **Simulator**: leave host as `127.0.0.1` — no extra config.

> ⚠️ When binding to `0.0.0.0`, set `HERMES_VOICE_TOKEN=<random>` and put the same token in the iOS Settings auth field. The token is required on every request when set.

## Env vars (see `backend/.env.example`)

| Variable | Default | What it does |
|---|---|---|
| `HERMES_VOICE_HOST` | `127.0.0.1` | Bind address (use `0.0.0.0` over Tailscale/LAN only). |
| `HERMES_VOICE_PORT` | `8765` | Listen port. |
| `HERMES_VOICE_MOCK` | unset | Force mock mode even with keys present. |
| `HERMES_VOICE_TOKEN` | unset | If set, requests must send `X-Hermes-Voice-Token`. |
| `HERMES_BIN` | `hermes` | Path/name of the Hermes CLI. |
| `HERMES_EXTRA_ARGS` | unset | Appended to every `hermes chat` (e.g. `-t apple_notes,apple_reminders -m anthropic/claude-sonnet-4`). |
| `HERMES_TIMEOUT_SECONDS` | `180` | Per-turn timeout. |
| `STT_PROVIDER` | auto | `openai` / `groq` / `elevenlabs` / `local_whisper` / `mock`. |
| `OPENAI_API_KEY` / `VOICE_TOOLS_OPENAI_KEY` | unset | Used for OpenAI Whisper + OpenAI TTS. |
| `GROQ_API_KEY` | unset | Groq Whisper-large-v3-turbo (very fast). |
| `LOCAL_WHISPER_MODEL` | `base.en` | faster-whisper model name. |
| `TTS_PROVIDER` | auto | `elevenlabs` / `openai` / `local_piper` / `mock`. |
| `ELEVENLABS_API_KEY` | unset | ElevenLabs key (powers TTS *and* Scribe STT). |
| `ELEVENLABS_VOICE_ID` | `nPczCjzI2devNBz1zQrb` | Brian (deeper narrator). |
| `OPENAI_TTS_MODEL` | `tts-1` | `tts-1`, `tts-1-hd`, or `gpt-4o-mini-tts`. |
| `OPENAI_TTS_VOICE` | `onyx` | Masculine fallback voice. |
| `PIPER_VOICE_PATH` | unset | Absolute path to a `.onnx` voice (with `.onnx.json` next to it). |

## Auto-starting the backend (launchd)

For "always-up" reliability, install the LaunchAgent so the backend starts at
login and respawns on crash. A second LaunchAgent handles cert renewal on a
30-day cadence:

```bash
# Backend service
cp backend/launchd/dev.finklea.harnessvoice.backend.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) \
  ~/Library/LaunchAgents/dev.finklea.harnessvoice.backend.plist

# Cert renewal (every 30 days)
cp backend/launchd/dev.finklea.harnessvoice.cert-renew.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) \
  ~/Library/LaunchAgents/dev.finklea.harnessvoice.cert-renew.plist
```

Verify it's running: `launchctl print gui/$(id -u)/dev.finklea.harnessvoice.backend`
Tail logs: `tail -F /tmp/harness-voice.log`
Force a cert renewal now: `launchctl kickstart -k gui/$(id -u)/dev.finklea.harnessvoice.cert-renew`

The iOS app's Settings → Diagnostics screen shows "Backend last seen" so you
can spot the moment it goes unreachable.

## Latency tuning

The slowest part of any turn is Hermes' LLM thinking + tool-call round-trips
(2–6s typically). Beyond that, two knobs are worth knowing:

- **STT provider**: Groq's Whisper-large-v3-turbo is noticeably faster than
  OpenAI's whisper-1 — often 200–400ms vs 600–1000ms for short utterances.
  Set `STT_PROVIDER=groq` and `GROQ_API_KEY=...` in `.env` to A/B.
- **TTS first-byte**: ElevenLabs `eleven_turbo_v2_5` delivers first audio in
  ~300ms. The `_run_turn` flow kicks off TTS streaming *before* the tool-call
  audit completes, so audit time doesn't push perceived audio start.

## A/B-ing STT providers

If you have multiple keys set, the backend auto-picks `openai` first. To force a comparison without removing keys:

```bash
# in backend/.env
STT_PROVIDER=elevenlabs   # Scribe v1 — strong WER, good with accents
# STT_PROVIDER=groq       # whisper-large-v3-turbo — fastest by wall clock
# STT_PROVIDER=openai     # whisper-1 — the safe default
# STT_PROVIDER=local_whisper  # offline, requires '.[local]'
```

Restart the backend and call `/health` to confirm: the `stt.name` field reports which provider is live.

Scribe v2 streaming (the WebSocket "Scribe Realtime" product) is the upgrade path when we add streaming STT — it slots into the same `STTProvider` Protocol.

## Fully local mode (no API calls)

```bash
cd backend
uv sync --extra dev --extra local
# Download a Piper voice (one-time, ~60MB):
mkdir -p ~/.local/share/piper-voices && cd ~/.local/share/piper-voices
curl -L -o en_US-ryan-high.onnx \
  https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/ryan/high/en_US-ryan-high.onnx
curl -L -o en_US-ryan-high.onnx.json \
  https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/ryan/high/en_US-ryan-high.onnx.json
```

Then in `.env`:

```bash
STT_PROVIDER=local_whisper
TTS_PROVIDER=local_piper
PIPER_VOICE_PATH=/Users/you/.local/share/piper-voices/en_US-ryan-high.onnx
```

Notes:
- `faster-whisper` runs on CPU with int8 quantization on Apple Silicon — fine for short utterances. (Metal is not yet supported by CTranslate2.)
- `Parakeet` would be the upgrade path for STT but its Apple Silicon story is still rough. There's a `# TODO` marker in `backend/app/stt/local_whisper.py` where the swap-in would go.
- First Whisper transcription downloads the model (~150MB for `base.en`).

## Tests

```bash
cd backend
uv run pytest -q
```

Provider abstractions are unit-testable without network: tests inject `FakeHermes` and `FakeTTS` directly into the app factory.

## Current limitations

- **No streaming.** v1 records the full utterance, sends after stop, gets one complete response, plays it. Real-time partial transcripts and streaming TTS are roadmap items.
- **No interruption / barge-in.** While Hermes is speaking, the mic button is disabled.
- **No wake word / VAD.** Push-to-talk only.
- **Session continuity is best-effort.** The backend stores `session_id` round-trips, but if Hermes wipes a session, the next turn starts fresh.
- **No approval cards.** Hermes runs whatever tools you have configured. Use `HERMES_EXTRA_ARGS` to restrict toolsets (e.g. `-t apple_notes,apple_reminders` for read-mostly).

## Roadmap

- [ ] WebSocket transport for the iOS ↔ backend leg (replace HTTP POSTs).
- [ ] Streaming STT — partial transcripts visible in the transcript as you speak.
- [ ] ElevenLabs streaming TTS — playback starts before synthesis finishes.
- [ ] Interruption / barge-in — tapping the mic while Hermes speaks cuts him off and starts recording.
- [ ] Approval cards — backend surfaces "Hermes wants to *send iMessage to Dad: ...*", iOS shows an Approve/Deny card before the action runs.
- [ ] iOS Shortcut: "Hey Siri, ask Hermes ..." → fires `/api/text` and speaks the reply.
- [ ] Home Assistant voice-satellite integration — share the same backend with HA Assist.
- [ ] Background audio session improvements (currently playback uses `.duckOthers`).
- [ ] Swap faster-whisper for NVIDIA Parakeet (`parakeet-mlx`) once it's plug-and-play on Apple Silicon.

## Layout

```
hermes-voice/
├── backend/
│   ├── app/
│   │   ├── main.py            # FastAPI app + route registration
│   │   ├── config.py          # env-driven Settings
│   │   ├── models.py          # request/response shapes
│   │   ├── hermes.py          # subprocess-based HermesClient + MockHermesClient
│   │   ├── audio_store.py     # short-lived synthesized-audio cache
│   │   ├── stt/               # provider Protocol + openai/groq/local/mock impls
│   │   └── tts/               # provider Protocol + elevenlabs/openai/piper/mock impls
│   ├── tests/                 # pytest (no network, all-fake providers)
│   ├── pyproject.toml
│   └── .env.example
├── ios/HermesVoice/
│   ├── project.yml            # XcodeGen project spec
│   └── HermesVoice/
│       ├── HermesVoiceApp.swift
│       ├── Models/            # Message, AppSettings
│       ├── Services/          # VoiceRecorder, AudioPlayer, HermesVoiceAPI
│       ├── ViewModels/        # ConversationViewModel (state machine)
│       └── Views/             # MainView, TranscriptView, PushToTalkButton, SettingsView
└── README.md
```
