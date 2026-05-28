# Schedules — User setup guide

Three pieces have to be wired up before recurring voice schedules work end-to-end. Phase A + B + C give you the code; this is the operator side.

## 1. Phase B — APNs key (one-time, ~10 minutes)

Push notifications need an APNs auth key (`.p8`) from Apple Developer.

1. Go to <https://developer.apple.com/account/resources/authkeys/list>
2. Click **+** to create a new key.
3. Name it (e.g. "Hermes Voice push"), check **Apple Push Notifications service (APNs)**, continue.
4. Click **Continue → Register**, then **Download**. **One-time download — Apple never re-issues it.**
5. Note the **Key ID** (10 chars, shown after registration) and your **Team ID** (top-right of the developer portal).
6. Store the `.p8` somewhere stable: `mkdir -p ~/.hermes-voice && mv ~/Downloads/AuthKey_XXXX.p8 ~/.hermes-voice/apns-key.p8 && chmod 600 ~/.hermes-voice/apns-key.p8`
7. Add to `backend/.env`:
   ```
   APNS_KEY_PATH=/Users/YOU/.hermes-voice/apns-key.p8
   APNS_KEY_ID=ABCDEFGHIJ
   APNS_TEAM_ID=K7CBQW6MPG
   APNS_BUNDLE_ID=dev.finklea.hermesvoice
   APNS_USE_SANDBOX=true        # set false after you ship via TestFlight or App Store
   ```
8. Restart the backend (`launchctl kickstart -k gui/$UID/dev.finklea.hermesvoice.backend` if you're using the LaunchAgent).
9. On the iPhone: open Hermes Voice → Settings → Notifications → flip **Allow notifications** ON. Accept the OS prompt. The app POSTs your APNs device token to `/api/devices`.
10. Verify: `sqlite3 ~/.hermes-voice/schedules.db 'select platform, environment, registered_at from devices;'` should show one row.

Without the `.p8` configured, schedules still fire — you'll just see them in History instead of getting a notification.

## 2. Phase C — Wire the MCP server into Hermes Agent

The MCP server lives in this repo (`app.mcp_schedules`) and proxies Hermes tool calls to the FastAPI backend.

### Register it as a Hermes MCP server

From any directory:

```bash
hermes mcp add hermes-voice \
  --command uv \
  --args run --project /Users/YOU/git/hermes-voice/backend python -m app.mcp_schedules \
  --env "HERMES_VOICE_BASE_URL=http://127.0.0.1:8765" \
        "HERMES_VOICE_TOKEN=$(security find-generic-password -a $USER -s HERMES_VOICE_TOKEN -w 2>/dev/null)"
```

Adjust:
- `/Users/YOU/git/hermes-voice/backend` to your absolute path.
- `HERMES_VOICE_TOKEN` lookup if you store the token differently (env, .env file, etc.).

### Verify

```bash
hermes mcp test hermes-voice
hermes mcp list      # should show hermes-voice with 3 tools enabled
hermes tools list | grep hermes-voice
```

You should see three tools:
- `hermes-voice:create_schedule`
- `hermes-voice:list_schedules`
- `hermes-voice:delete_schedule`

### Voice flows that should work

| You say | Hermes does |
|---|---|
| "Every 5 minutes give me the weather" | `create_schedule(cadence_seconds=300, prompt="give me the weather", display_name="weather updates")` |
| "Every two hours summarize my unread emails" | `create_schedule(cadence_seconds=7200, prompt="summarize unread emails", display_name="email summary")` |
| "What's scheduled?" | `list_schedules()` |
| "Stop the weather updates" | `list_schedules()` → finds match → `delete_schedule(id=...)` |
| "Stop all schedules" | iterates `delete_schedule` per result of `list_schedules()` |

Hermes does the cadence parsing — we just give it tools that take seconds. The LLM is good at converting "every 5 minutes" → 300, "twice an hour" → 1800, etc.

### Troubleshooting

- **`hermes mcp test` fails with connection refused**: the backend isn't running. Start it. The MCP server is a thin proxy and goes through HTTP.
- **`X-Hermes-Voice-Token` rejected**: `HERMES_VOICE_TOKEN` env passed to `hermes mcp add` doesn't match `backend/.env`. Re-run `mcp add` with the right value.
- **TLS cert verification failure**: only happens if you point `HERMES_VOICE_BASE_URL` at an `https://` URL with a custom CA. Either point it at `http://127.0.0.1:8765` (same machine, no TLS needed) or set `HERMES_VOICE_CA_BUNDLE=/path/to/ca.pem` in the env passed to `mcp add`.

## 3. Test end-to-end

```bash
# Pick a fast cadence so you don't wait long.
hermes chat -z "every minute say what time it is, call this clock test"
# Expect Hermes to use create_schedule. Verify:
curl -H "X-Hermes-Voice-Token: $TOKEN" http://127.0.0.1:8765/api/schedules

# Wait ~60-90s. Check that it fired:
curl -H "X-Hermes-Voice-Token: $TOKEN" http://127.0.0.1:8765/api/sessions | jq '.[0]'

# Should also see a push on the phone if APNs is configured.

# Clean up via voice:
hermes chat -z "stop the clock test"
```

If push didn't arrive but the session DID appear, APNs is the issue — check `tail -f ~/Library/Logs/HermesVoice/backend.log` for push warnings. If neither fired, the schedule didn't get created — check `hermes mcp list` and `hermes tools list`.
