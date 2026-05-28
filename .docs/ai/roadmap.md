# Roadmap

> Durable goals and milestones. Updated when scope changes, not every session.

## Vision

Hermes Voice — voice-native iOS + watchOS interface to a self-hosted Hermes Agent on macOS, secured via Tailscale. Push-to-talk, streaming STT/TTS, tool-call audit, conversation history. Personal operator-style "Jarvis" for memory capture, control, and admin.

## Now / Next / Later

### Now
- [x] G — App polish + frontend-design redesign (E · Focus / Now-Playing — deepened) — built; awaiting on-device visual review

### Next — scoped via `.docs/ai/phases/schedules-spec.md`
- [x] Schedules Phase A — store + cron + in-app UI (no push)
- [x] Schedules Phase B — APNs + chime + foreground auto-play (code complete; needs user's APNs .p8 key to actually deliver)
- [x] Schedules Phase C — Hermes voice creation/cancel via MCP — REGISTERED + VERIFIED LIVE (create + delete by voice both confirmed)

### In progress — TestFlight (pulled forward; unblocks APNs topic-scoping + on-device testing)
- [x] Code prep: Push entitlement (`aps-environment`), version numbers, signing config
- [ ] User: create App Store Connect record + archive + upload (see `ios/docs/testflight.md`)
- [ ] User: create topic-scoped APNs key (App ID surfaces after first archive)
- [ ] Wire APNs key into `backend/.env`, register device, fire test schedule

### Then — daily-driver features (sequenced)
- [ ] Bonjour/mDNS backend discovery + first-launch onboarding
- [x] Live Activity / Dynamic Island — SHIPPED (`0b204e1`, 2026-05-28); v1 informational (tap opens app), interactive stop button is v2 per `.docs/ai/phases/live-activity-spec.md`. Build + tests re-verified green. Follow-ups: `finish()` race, `staleDate`, request-error logging; on-device smoke test still pending.
- [ ] CarPlay support — **probe entitlement first**, Apple may refuse indie request

### Redesign polish (interleave with above)
- [ ] On-device walkthrough every state, fix layout bugs
- [ ] Scrollback tap → in-app expand transcript (today it opens HistoryView sheet)
- [ ] ActionCard variants beyond calendar (device list, todo, file results) — driven by Hermes tool availability
- [ ] Voice picker in Settings wired to ElevenLabs voices

### Dropped
- ~~D — Wake word~~ — iOS won't allow background mic for indie apps; Siri shortcut (`AskHermesIntent`) covers the lock-screen case. Foreground-only wake-word didn't earn its keep.

### Later
- [ ] TestFlight prep (diff project.yml against patchstand-ios / open-feelings-ios)
- [ ] App Store hardening (tighten ATS via NSExceptionDomains rather than NSAllowsArbitraryLoads)

## Completed

- [x] Streaming TTS + barge-in (cancellable Task pattern)
- [x] ElevenLabs Scribe + OpenAI Whisper STT options
- [x] Conversation history (backend `/api/sessions` + iOS UI + audio replay)
- [x] C — Backend reliability (launchd + Tailscale cert renewal + iOS last-seen indicator)
- [x] F — Latency wins (parallelize audit/TTS, A/B Groq STT)
- [x] E — Apple Watch companion (one-tap memory capture, WCSession-relayed)

## Backlog

> Self-contained items any agent can execute.

### Scheduled recurring Hermes messages

**Status**: Scoped — see `.docs/ai/phases/schedules-spec.md` for full spec. Phase A is the next executable chunk.

## Constraints

- iOS 17+ / watchOS 10+
- No new third-party iOS dependencies if avoidable (use Apple frameworks)
- Backend stays a single FastAPI app (no microservices)
- Tailscale-only access (CGNAT 100.64/10); ATS configured to allow this
