# Server Profiles and Fast Switching — Design

## Goal

Let one iPhone explicitly switch between independent Hermes Voice backends running on different laptops. A selected profile determines where all new work goes; the app must never silently redirect work to a different laptop.

## Decisions

- Use named, saved backend profiles, not two fixed slots.
- Switch from a picker in the main-screen header; edit profiles in Settings.
- A profile owns its URL, token, and selected harness (`hermes`, `claude`, `codex`, or `opencode`).
- On-device voice/STT/VAD, filler verbosity, input mode, and notification preference stay phone-wide.
- Switching is explicit only. There is no automatic reachability failover.
- Switching is allowed only while the conversation is at rest. A switch starts a new local conversation.
- Keep the existing UserDefaults token-storage model; Keychain migration is not part of this feature.

## Data model and persistence

Add a Codable `BackendProfile` value with:

- stable UUID identifier
- user-editable display name
- backend base URL
- authentication token
- selected harness

`AppSettings` persists the profile array and active profile ID as UserDefaults data. Existing `backendURL`, `authToken`, and `selectedHarness` call sites continue to read the currently active profile through `AppSettings`, avoiding a broad API-client rewrite.

### Upgrade migration

On first launch after upgrading:

1. If no profile payload exists, read the legacy URL, token, and selected-harness keys.
2. Create one profile from those values.
3. Derive a readable initial name from the URL host; use a stable generic name if the URL cannot provide one.
4. Persist the new profile payload and mark it active.

The legacy keys remain harmless compatibility input for this one migration; the profile payload becomes authoritative. A fresh installation still uses onboarding to create its first profile.

## User interface

### Main header picker

The existing agent title stays in the navigation header. Its active server name appears beneath it with a disclosure indicator; the complete header is one accessible button.

Tapping opens a compact server menu:

- every saved profile appears by its name;
- the active profile has a checkmark;
- selecting another eligible profile switches immediately;
- a `Manage servers…` action opens Settings.

The picker does not continuously ping or rank servers. A backend that is down is still selectable so the user retains control and can retry it deliberately.

While recording, sending, thinking, speaking, or awaiting a voice approval/question, the header picker is disabled. Its accessibility hint explains that the current turn must finish or be cancelled first.

### Settings management

Replace the single raw BACKEND URL/token editor with a SERVERS section:

- list saved profiles, with the active profile identified;
- add a profile;
- edit a profile name, URL, token, and its harness selection;
- test a profile connection;
- delete a non-active profile, but never the final remaining profile.

New and edited profiles require a successful `/health` test before activation. Editing an existing non-active profile does not alter the current server until the user switches to it. Profile name defaults from the URL host but is always editable.

## Switching and integration behavior

When the user selects another profile while at rest:

1. Clear the current in-memory messages, session ID, attachment metadata, pending approval/question, and scheduled-arrival badge.
2. Activate the selected profile, including its saved harness.
3. Leave server-owned data isolated: History, sessions, schedules, replay, and harness availability are fetched from the active backend only.
4. If notifications are enabled and iOS has an APNs device token, register that token with the newly active backend. This allows each laptop to deliver its own scheduled notifications.

No backend endpoint or backend data migration is required. The phone simply changes which existing backend it addresses.

The app must not switch during a live turn. It does not cancel and reroute work automatically, because the source backend may have started a side-effectful tool action. The user may cancel first, then switch.

Siri/Shortcuts and Watch requests use the active profile through the existing shared settings, so the selected server applies consistently across app entry points.

## Error handling

- Invalid profile data during decode is ignored as a whole and falls back to migration/default onboarding rather than crashing.
- `/health` failures show the existing connection error and do not activate a newly added profile.
- APNs registration failure after a successful switch is logged as today and does not undo the switch.
- A profile may be deleted only when inactive and when another profile remains.

## Testing and verification

### Automated

Add Swift tests for:

- legacy settings migrate to one active profile without losing URL, token, or harness;
- profile persistence and active-profile restoration;
- switching restores the selected profile's harness;
- profile deletion rejects active and final profiles;
- a conversation switch clears local session/attachment/pending state before the next turn.

Run the project’s existing iOS test target and simulator build after regenerating the Xcode project if new source files require it.

### On-device

1. Add both laptops using their Tailscale/MagicDNS backend URLs and tokens.
2. Switch using the header; confirm each new turn reaches only the chosen laptop.
3. Confirm each profile restores its own agent choice.
4. Confirm History and schedules show the selected laptop’s data only.
5. Start a turn and confirm server switching is unavailable until it is cancelled or completes.
6. If notifications are enabled, confirm the newly selected backend receives the device registration.

## Out of scope

- Automatic server failover, load balancing, or health-based routing.
- Synchronizing Hermes sessions, history, schedules, or agent state between laptops.
- A backend API change or shared centralized server registry.
- Keychain migration for stored tokens.
