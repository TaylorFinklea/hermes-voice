# Live Activity / Dynamic Island — Spec

> Lock-screen + Dynamic Island presence for in-flight Hermes turns. ActivityKit, local updates (no push-to-update).

## Decisions (locked)

| Decision | Choice |
|---|---|
| Lifecycle | Show during the waiting+playback window: `.sending`/`.thinking` → `.speaking`. Ends on `.idle`/`.error`. Recording excluded. |
| Stop button | v1 informational (tap opens app). Interactive `LiveActivityIntent` stop button is v2 (needs playback extracted into a shared controller). |
| Schedules | Scheduled-fire foreground auto-play raises the same activity (driven from NotificationManager, not the VM state machine). |

## Why local updates (not push)

The app is always running when our triggers fire: PTT turns are foreground; scheduled-fire auto-play only happens in `willPresent` (foreground); background audio keeps the app alive through `.speaking`. So `Activity.request` / `.update` / `.end` run in-process. No ActivityKit push token, no `aps-environment` Live Activity push needed. Siri turns (`openAppWhenRun=false`) don't go through the VM and won't raise an activity — acceptable.

## Components

- **`HermesVoice/Shared/HermesActivityAttributes.swift`** — `ActivityAttributes` with `ContentState { phase: Phase (.thinking/.speaking), detail: String, startedAt: Date }`. Compiled into BOTH app + widget targets (ActivityKit requires identical type). Lives under `HermesVoice/` so the app target picks it up automatically; widget target adds the explicit path.
- **`HermesVoice/Services/LiveActivityController.swift`** — `@MainActor` singleton: `showThinking(detail:)`, `showSpeaking(detail:)`, `finish()`. Guards on `ActivityAuthorizationInfo().areActivitiesEnabled`; swallows request errors (best-effort).
- **`ConversationViewModel`** — `state` gets a `didSet` that drives the controller: `.sending/.thinking → showThinking(lastUserText)`, `.speaking → showSpeaking(lastAssistantText)`, `.idle/.error/.recording → finish()`.
- **`NotificationManager.handleForegroundArrival`** — wraps the chime+replay in `showSpeaking(detail: body)` … `finish()`.
- **`HermesVoiceWidget`** — NEW app-extension target. `HermesVoiceWidgetBundle.swift` (`@main` WidgetBundle) + `HermesVoiceLiveActivity.swift` (`ActivityConfiguration`: lock-screen banner + Dynamic Island compact/expanded/minimal). Brand-styled via the shared `Brand.swift` (added to widget sources).
- **project.yml** — add the extension target (`type: app-extension`, bundle id `dev.finklea.hermesvoice.widget`, `NSExtensionPointIdentifier: com.apple.widgetkit-extension`), embed in app, add `NSSupportsLiveActivities: true` to app Info.plist.

## UI (brand)

- Lock screen: winged-H glyph + "HERMES" • state pill ("THINKING…" bronze / "SPEAKING" gold) • `detail` text (1-2 lines) • elapsed timer from `startedAt`.
- Dynamic Island: compact leading = mic/wave glyph tinted by phase; compact trailing = elapsed; expanded = state + detail snippet; minimal = single phase glyph.

## Verify

- Build iOS + widget extension clean.
- On device: fire a PTT turn → "THINKING…" then "SPEAKING" on lock screen + Dynamic Island, elapsed ticking, ends on idle.
- Fire a scheduled turn with phone locked-then-foregrounded → activity shows during auto-play.
- Tapping the activity opens the app.

## v2 (deferred)

Interactive stop button: extract `AudioPlayer` control into a shared `PlaybackController` singleton (out of the SwiftUI VM) so a `LiveActivityIntent` button can call `stop()` from the widget process. Then add a Button(intent:) to the speaking-phase UI.
