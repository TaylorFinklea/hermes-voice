# Backend

FastAPI service mediating between the iOS app and the local Hermes CLI.

See the [top-level README](../README.md) for full setup. Quick reference:

```bash
uv sync --extra dev               # base + test deps
uv sync --extra dev --extra local # add faster-whisper + piper
uv run python -m app              # start server (auto-loads backend/.env)
uv run pytest -q                  # run tests (env-isolated per test)
```

`backend/.env` is loaded automatically on startup via `python-dotenv`. Shell env vars still win over .env when both are set — useful for one-off overrides like `STT_PROVIDER=elevenlabs uv run python -m app`.

## Endpoints

| Method | Path | Body | Returns |
|---|---|---|---|
| `GET` | `/health` | — | `{status, mock, hermes, stt, tts}` |
| `POST` | `/api/text` | `{text, session_id?}` | `TurnResponse` |
| `POST` | `/api/audio` | multipart `file=<audio>` `session_id=<id>?` | `TurnResponse` |
| `GET` | `/api/audio/{id}` | — | audio bytes (mp3 or wav) |

`TurnResponse`:
```json
{
  "session_id": "20260524_153729_be415a",
  "user_text": "what time is sunset",
  "assistant_text": "Sunset in Austin today is 8:32 PM.",
  "audio_url": "/api/audio/abc123_..."
}
```

`audio_url` is `null` when no TTS provider is configured — the iOS app falls back to displaying the text.

## Provider selection

Each provider has a `make_*(settings)` factory. Selection order (first non-empty wins) is documented at the top of `app/stt/__init__.py` and `app/tts/__init__.py`. Adding a provider:

1. Create `app/{stt,tts}/<name>.py` implementing the Protocol (`name`, `describe()`, `transcribe()` or `synthesize()`).
2. Add a branch in the factory.
3. Add a key/config slot to `Settings` and `.env.example`.
4. Add a unit test in `tests/test_providers.py`.

## Hermes session continuity

`HermesClient` parses `session_id: <id>` from stderr on every turn, and passes it back via `--resume <id>` on subsequent turns. The iOS app threads `session_id` through `TurnResponse → next request`, so a conversation keeps Hermes' tool state across turns.

If Hermes ever returns an empty session_id, the client surfaces an empty string — the iOS app then starts a fresh session on the next turn.
