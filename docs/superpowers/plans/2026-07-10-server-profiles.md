# Server Profiles and Fast Switching Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow the iPhone app to switch explicitly and safely between saved, independent Hermes Voice backend profiles for different laptops.

**Architecture:** A pure Codable `BackendProfile` model holds server-specific state. `AppSettings` persists the profile collection and exposes the active profile through its existing URL/token/harness properties, so existing transport call sites retain their current shape. The main header provides the fast selector, while focused profile-management views own add/edit/test/delete flows.

**Tech Stack:** Swift 5.10, SwiftUI, XCTest, UserDefaults, URLSession via existing `HermesVoiceAPI`, XcodeGen.

## Global Constraints

- iOS deployment target remains 17.0; do not add third-party dependencies.
- A profile contains only a UUID, editable name, backend URL, token, and selected harness.
- On-device voice/STT/VAD, filler verbosity, input mode, and notification preference remain phone-wide.
- Server selection is explicit: no automatic health-based fallback, load balancing, or session synchronization.
- Do not switch while recording, sending, thinking, speaking, hands-free listening, or awaiting an approval/question.
- A switch clears the in-memory conversation and routes subsequent app, Watch, and Siri work to the selected profile.
- Retain the existing UserDefaults token-storage model; Keychain migration is out of scope.

---

## File structure

| Path | Responsibility |
| --- | --- |
| `ios/HermesVoice/HermesVoice/Models/BackendProfile.swift` | Pure profile model, URL-derived default name, and profile-persistence payload. |
| `ios/HermesVoice/HermesVoice/Models/AppSettings.swift` | Migration, profile persistence, active-profile accessors, and profile mutations. |
| `ios/HermesVoice/HermesVoice/Views/BackendProfileViews.swift` | Header picker plus focused server list/editor views; connection-test UI belongs here. |
| `ios/HermesVoice/HermesVoice/Views/MainView.swift` | Hosts the header picker and coordinates a safe switch with the conversation and notification managers. |
| `ios/HermesVoice/HermesVoice/Views/SettingsView.swift` | Replaces raw backend fields with a Servers entry point while retaining unrelated settings. |
| `ios/HermesVoice/HermesVoice/Views/OnboardingView.swift` | Configures the initial active profile after its existing health check succeeds. |
| `ios/HermesVoice/HermesVoice/ViewModels/ConversationViewModel.swift` | Defines whether a backend can change and atomically resets local conversation state for a permitted switch. |
| `ios/HermesVoice/HermesVoice/Services/NotificationManager.swift` | Re-registers a cached APNs token with the newly active backend. |
| `ios/HermesVoice/HermesVoice/Intents/AskHermesIntent.swift` | Resolves Siri’s URL/token and profile identity from the active persisted profile, with legacy fallback. |
| `ios/HermesVoice/HermesVoiceTests/BackendProfileTests.swift` | Pure profile naming, persistence, migration, deletion, and active-profile tests. |
| `ios/HermesVoice/HermesVoiceTests/TurnStateMachineTests.swift` | Adds safe-switch reset coverage through the existing injected `TurnTransport` seam. |

## Task 1: Profile model, persistence, and legacy migration

**Files:**
- Create: `ios/HermesVoice/HermesVoice/Models/BackendProfile.swift`
- Modify: `ios/HermesVoice/HermesVoice/Models/AppSettings.swift`
- Create: `ios/HermesVoice/HermesVoiceTests/BackendProfileTests.swift`

**Interfaces:**
- Produces `BackendProfile: Codable, Equatable, Identifiable` with `id`, `name`, `url`, `authToken`, and `selectedHarness`.
- Produces `AppSettings.backendProfiles`, `AppSettings.activeBackendProfile`, `activateProfile(id:)`, `saveProfile(_:)`, and `removeProfile(id:)`.
- Preserves mutable `AppSettings.backendURL`, `authToken`, and `selectedHarness` as views of the active profile so existing `HermesVoiceAPI` call sites continue to compile.

- [ ] **Step 1: Write profile-model tests**

Create `BackendProfileTests.swift` with an isolated `UserDefaults` suite per test. Cover host-name derivation, the legacy-key migration, profile-specific harness restoration, and deletion constraints:

```swift
@MainActor
final class BackendProfileTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        let suite = "BackendProfileTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    func testMigratesLegacyBackendIntoActiveProfile() {
        defaults.set("https://studio.tailnet.ts.net:8765", forKey: "hv.backendURL")
        defaults.set("token-a", forKey: "hv.authToken")
        defaults.set("claude", forKey: "hv.selectedHarness")

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.backendProfiles.count, 1)
        XCTAssertEqual(settings.backendURL, "https://studio.tailnet.ts.net:8765")
        XCTAssertEqual(settings.authToken, "token-a")
        XCTAssertEqual(settings.selectedHarness, "claude")
        XCTAssertEqual(settings.activeBackendProfile.name, "studio.tailnet.ts.net")
    }

    func testActivatingProfileRestoresItsHarness() {
        let settings = AppSettings(defaults: defaults)
        let first = settings.activeBackendProfile
        settings.selectedHarness = "claude"
        let second = BackendProfile(name: "Laptop", url: "https://laptop.example:8765", authToken: "b", selectedHarness: "codex")
        settings.saveProfile(second)

        XCTAssertTrue(settings.activateProfile(id: second.id))
        XCTAssertEqual(settings.selectedHarness, "codex")
        XCTAssertTrue(settings.activateProfile(id: first.id))
        XCTAssertEqual(settings.selectedHarness, "claude")
    }

    func testCannotDeleteActiveOrOnlyProfile() {
        let settings = AppSettings(defaults: defaults)
        let only = settings.activeBackendProfile
        XCTAssertFalse(settings.removeProfile(id: only.id))

        let other = BackendProfile(name: "Other", url: "https://other.example:8765", authToken: "", selectedHarness: "hermes")
        settings.saveProfile(other)
        XCTAssertFalse(settings.removeProfile(id: only.id))
        XCTAssertTrue(settings.removeProfile(id: other.id))
    }
}
```

- [ ] **Step 2: Regenerate and run the new tests to verify they fail**

Run:

```bash
xcodegen generate --spec ios/HermesVoice/project.yml
```

Expected: `Generated project`; the new test source is included in the test target.

Then run:

```bash
xcodebuild -project ios/HermesVoice/HermesVoice.xcodeproj -scheme HermesVoice -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:HermesVoiceTests/BackendProfileTests test
```

Expected: compilation fails because `BackendProfile`, the injectable `AppSettings(defaults:)` initializer, and profile operations do not exist.

- [ ] **Step 3: Add the pure model and the profile-backed settings API**

Create the model with this public shape:

```swift
struct BackendProfile: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var url: String
    var authToken: String
    var selectedHarness: String

    init(id: UUID = UUID(), name: String, url: String, authToken: String, selectedHarness: String) {
        self.id = id
        self.name = name
        self.url = url
        self.authToken = authToken
        self.selectedHarness = selectedHarness
    }

    static func suggestedName(for url: String) -> String {
        guard let host = URL(string: url)?.host, !host.isEmpty else {
            return "Hermes server"
        }
        return host
    }
}
```

Refactor `AppSettings` to retain one `UserDefaults` instance injected by `init(defaults: UserDefaults = .standard)`. Decode a single profile-array payload and an active-ID payload. When the payload is absent, migrate the existing `hv.backendURL`, `hv.authToken`, and `hv.selectedHarness` values into exactly one active profile, then persist the new payload. A fresh install retains the existing loopback default and onboarding gate.

Implement these operations with the listed invariants:

```swift
var activeBackendProfile: BackendProfile { get }
func activateProfile(id: UUID) -> Bool       // false for an unknown ID
func saveProfile(_ profile: BackendProfile)  // replace same ID or append new
func removeProfile(id: UUID) -> Bool         // false for active, unknown, or final profile
```

Keep the old URL, token, and harness property names writable by updating the active profile and persisting the collection. Update the legacy URL/token/harness keys whenever the active profile changes so the current App Intent fallback remains valid during this task. Use `BackendProfile.suggestedName(for:)` for migrated data and never persist a blank name.

- [ ] **Step 4: Regenerate, then run profile tests and the full iOS test target**

Run:

```bash
xcodegen generate --spec ios/HermesVoice/project.yml
```

Expected: `Generated project`; the new model source is included in the app target.

Then run:

```bash
xcodebuild -project ios/HermesVoice/HermesVoice.xcodeproj -scheme HermesVoice -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:HermesVoiceTests/BackendProfileTests test
```

Expected: `TEST SUCCEEDED`.

Then run:

```bash
xcodebuild -project ios/HermesVoice/HermesVoice.xcodeproj -scheme HermesVoice -destination 'platform=iOS Simulator,name=iPhone 16' test
```

Expected: `TEST SUCCEEDED`; existing settings consumers compile against the active-profile accessors.

- [ ] **Step 5: Commit the persistence layer**

```bash
git add ios/HermesVoice/HermesVoice/Models/BackendProfile.swift ios/HermesVoice/HermesVoice/Models/AppSettings.swift ios/HermesVoice/HermesVoiceTests/BackendProfileTests.swift ios/HermesVoice/HermesVoice.xcodeproj/project.pbxproj
git commit -m "feat: persist backend server profiles"
```

## Task 2: Safe active-profile integration across app entry points

**Files:**
- Modify: `ios/HermesVoice/HermesVoice/ViewModels/ConversationViewModel.swift`
- Modify: `ios/HermesVoice/HermesVoice/Services/NotificationManager.swift`
- Modify: `ios/HermesVoice/HermesVoice/Intents/AskHermesIntent.swift`
- Modify: `ios/HermesVoice/HermesVoice/Views/OnboardingView.swift`
- Modify: `ios/HermesVoice/HermesVoiceTests/TurnStateMachineTests.swift`

**Interfaces:**
- Consumes `AppSettings.activateProfile(id:)` and `activeBackendProfile` from Task 1.
- Produces `ConversationViewModel.canSwitchBackend` and `switchBackend(to:) -> Bool`.
- Produces `NotificationManager.registerSavedDeviceWithActiveBackendIfNeeded()`.
- Preserves `SiriBackendConfig.load(defaults:)` but sources its URL/token and profile identity from the profile payload first and legacy keys only as a migration fallback.

- [ ] **Step 1: Write the conversation-switch test**

Add this test to `TurnStateMachineTests.swift`; it uses the existing `FakeTransport` and avoids live audio/networking:

```swift
func testSwitchBackendClearsConversationBeforeNextTurn() throws {
    let settings = makeSettings()
    let other = BackendProfile(name: "Laptop B", url: "https://b.example:8765", authToken: "b", selectedHarness: "codex")
    settings.saveProfile(other)
    let vm = ConversationViewModel(settings: settings, transport: FakeTransport())
    vm.attach(sessionId: "session-a", harness: "claude", repo: "/tmp/repo", readOnly: true)

    XCTAssertTrue(vm.switchBackend(to: other.id))
    XCTAssertEqual(settings.activeBackendProfile.id, other.id)
    XCTAssertEqual(settings.selectedHarness, "codex")
    XCTAssertNil(vm.sessionId)
    XCTAssertTrue(vm.messages.isEmpty)
    XCTAssertNil(vm.attachedRepo)
}
```

`attachedRepo` is already readable as `@Published private(set)`, so this test must not widen production visibility.

Also add a configuration test in `BackendProfileTests.swift`:

```swift
func testSiriConfigurationUsesActiveProfile() {
    let settings = AppSettings(defaults: defaults)
    let second = BackendProfile(name: "Laptop B", url: "https://b.example:8765", authToken: "token-b", selectedHarness: "hermes")
    settings.saveProfile(second)
    XCTAssertTrue(settings.activateProfile(id: second.id))

    let config = SiriBackendConfig.load(defaults: defaults)

    XCTAssertEqual(config.backendURL, second.url)
    XCTAssertEqual(config.authToken, second.authToken)
    XCTAssertEqual(config.profileID, second.id.uuidString)
}
```

- [ ] **Step 2: Run the focused tests to verify they fail**

Run:

```bash
xcodebuild -project ios/HermesVoice/HermesVoice.xcodeproj -scheme HermesVoice -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:HermesVoiceTests/TurnStateMachineTests/testSwitchBackendClearsConversationBeforeNextTurn -only-testing:HermesVoiceTests/BackendProfileTests/testSiriConfigurationUsesActiveProfile test
```

Expected: compilation fails because `switchBackend(to:)`, profile-aware Siri configuration, and the profile model are not yet integrated.

- [ ] **Step 3: Implement guarded switching and profile-aware entry points**

Add these VM semantics:

```swift
var canSwitchBackend: Bool {
    guard pendingApproval == nil, pendingQuestion == nil else { return false }
    switch state {
    case .idle, .error: return true
    case .recording, .sending, .thinking, .speaking: return false
    }
}

@discardableResult
func switchBackend(to profileID: UUID) -> Bool {
    guard canSwitchBackend, settings.activateProfile(id: profileID) else { return false }
    reset()
    return true
}
```

Do not cancel, reroute, or retry a live request. `reset()` already clears messages, session ID, attachment state, and pending approval/question; ensure its use leaves the VM idle after a permitted switch.

Add `NotificationManager.registerSavedDeviceWithActiveBackendIfNeeded()`. It must return early when notifications are disabled or `lastApnsToken` is empty; otherwise reuse the existing registration path with the current active URL/token. Call it only after a successful profile activation.

Change `SiriBackendConfig.load(defaults:)` to decode the active profile through an `AppSettings` static read helper that uses the same profile keys and falls back to legacy URL/token when no profile payload is present. Do not construct an observable `AppSettings` instance inside an App Intent. Add `profileID` to `SiriBackendConfig`; make `SiriSession.load(profileID:)` reject a persisted session whose profile ID differs, and make `SiriSession.save(_:profileID:)` persist the active profile ID alongside its session ID. This prevents Siri from sending a session identifier from laptop A to laptop B.

In `OnboardingView.testConnection()`, replace direct URL/token writes with an update of the initial active profile (using the health-tested URL/token and a suggested name), then retain the existing `markReachable()` and onboarding completion behavior.

- [ ] **Step 4: Run focused and full tests**

Run:

```bash
xcodebuild -project ios/HermesVoice/HermesVoice.xcodeproj -scheme HermesVoice -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:HermesVoiceTests/TurnStateMachineTests test
```

Expected: `TEST SUCCEEDED` including the new switch test.

Then run:

```bash
xcodebuild -project ios/HermesVoice/HermesVoice.xcodeproj -scheme HermesVoice -destination 'platform=iOS Simulator,name=iPhone 16' test
```

Expected: `TEST SUCCEEDED`.

- [ ] **Step 5: Commit active-profile integration**

```bash
git add ios/HermesVoice/HermesVoice/ViewModels/ConversationViewModel.swift ios/HermesVoice/HermesVoice/Services/NotificationManager.swift ios/HermesVoice/HermesVoice/Intents/AskHermesIntent.swift ios/HermesVoice/HermesVoice/Views/OnboardingView.swift ios/HermesVoice/HermesVoiceTests/TurnStateMachineTests.swift
git commit -m "feat: route app entry points through active server"
```

## Task 3: Server management views and health-gated profile edits

**Files:**
- Create: `ios/HermesVoice/HermesVoice/Views/BackendProfileViews.swift`
- Modify: `ios/HermesVoice/HermesVoice/Views/SettingsView.swift`
- Modify: `ios/HermesVoice/HermesVoice.xcodeproj/project.pbxproj` (generated)

**Interfaces:**
- Consumes `BackendProfile`, `AppSettings.saveProfile(_:)`, `activateProfile(id:)`, `removeProfile(id:)`, and `HermesVoiceAPI.health()`.
- Produces `BackendProfileManagerView` for the Settings navigation link and `BackendProfileEditorView` for add/edit flows.
- A successful editor health check is the only path that enables saving a new profile or committing an edited profile’s URL/token.

- [ ] **Step 1: Add the server-management UI with drafts only**

Create `BackendProfileViews.swift` with these focused views:

```swift
struct BackendProfileManagerView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var conversation: ConversationViewModel
}

struct BackendProfileEditorView: View {
    let existingProfile: BackendProfile?
    let onSaved: (BackendProfile) -> Void
}
```

`BackendProfileManagerView` lists names and active state, opens an editor for add/edit, and exposes deletion only for profiles where `profile.id != settings.activeBackendProfile.id` and `settings.backendProfiles.count > 1`. Keep profile changes local to editor `@State` drafts until they pass validation.

Replace `SettingsView.backendSection`’s raw URL and token fields with a `NavigationLink` to `BackendProfileManagerView`; leave every non-server section unchanged. Remove obsolete draft URL/token lifecycle code, `pinging`, `healthResult`, and the diagnostics health-output row only after the new view owns connection tests. Keep the existing active-server ping available in the manager rather than retaining a second raw backend form in Settings.

- [ ] **Step 2: Add health validation and save rules**

In `BackendProfileEditorView`, require non-empty trimmed name and URL. The Test button creates `HermesVoiceAPI(baseURL: draftURL, authToken: draftToken)` and awaits `health()`. Store the exact profile values that passed the latest check and invalidate that successful state whenever name, URL, or token changes.

Only enable Save when the current URL/token have a successful check. Saving creates or updates `BackendProfile`, calls `settings.saveProfile(_:)`, and returns to the manager. Editing a non-active profile never changes routing. Selecting a saved profile remains the header picker’s responsibility in Task 4.

Use the project’s existing dark `Form`, `HVFont`, `HVColor`, and explicit environment-object injection patterns. Do not add a dependency or a second onboarding path.

- [ ] **Step 3: Regenerate and build before committing**

Run:

```bash
xcodegen generate --spec ios/HermesVoice/project.yml
```

Expected: `Generated project` and the new Swift source appears in the app target.

Then run:

```bash
xcodebuild -project ios/HermesVoice/HermesVoice.xcodeproj -scheme HermesVoice -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit profile management**

```bash
git add ios/HermesVoice/HermesVoice/Views/BackendProfileViews.swift ios/HermesVoice/HermesVoice/Views/SettingsView.swift ios/HermesVoice/HermesVoice.xcodeproj/project.pbxproj
git commit -m "feat: manage saved server profiles"
```

## Task 4: Header picker and end-to-end switch wiring

**Files:**
- Modify: `ios/HermesVoice/HermesVoice/Views/BackendProfileViews.swift`
- Modify: `ios/HermesVoice/HermesVoice/Views/MainView.swift`

**Interfaces:**
- Consumes `ConversationViewModel.canSwitchBackend`, `switchBackend(to:)`, `ConversationModeController.isActive`, `NotificationManager.registerSavedDeviceWithActiveBackendIfNeeded()`, and the profile manager from prior tasks.
- Produces `BackendProfilePicker` used by `MainView`’s `.principal` toolbar item.

- [ ] **Step 1: Implement the picker view**

Add this interface to `BackendProfileViews.swift`:

```swift
struct BackendProfilePicker: View {
    @EnvironmentObject var settings: AppSettings
    let canSwitch: Bool
    let select: (BackendProfile) -> Void
    let manage: () -> Void
}
```

Render the existing active-agent title as the primary header text and the active profile name plus a chevron underneath. The menu lists every profile by name, shows a checkmark for the active ID, and includes `Manage servers…`. Keep the control accessible: label it with the active server name and explain why it is disabled when a turn is active.

- [ ] **Step 2: Wire MainView atomically**

Replace the principal `Text(settings.activeAgentTitle)` toolbar item with `BackendProfilePicker`. Its enabled condition is:

```swift
conversation.canSwitchBackend && !conversationMode.isActive
```

When a non-active profile is selected:

1. call `conversation.switchBackend(to:)`;
2. only if it returns true, call `notifications.clearArrival()`;
3. call `NotificationManager.shared.registerSavedDeviceWithActiveBackendIfNeeded()`;
4. preserve the main screen and show the normal empty idle state.

Route `Manage servers…` through the existing single-sheet mechanism by adding a server-management case to `MainView.ActiveSheet`, injecting `settings` and `conversation` exactly as its existing sheets do. Do not stack a second sheet modifier.

- [ ] **Step 3: Regenerate, test, and build**

Run:

```bash
xcodegen generate --spec ios/HermesVoice/project.yml
```

Expected: `Generated project`.

Run:

```bash
xcodebuild -project ios/HermesVoice/HermesVoice.xcodeproj -scheme HermesVoice -destination 'platform=iOS Simulator,name=iPhone 16' test
```

Expected: `TEST SUCCEEDED`.

Run:

```bash
xcodebuild -project ios/HermesVoice/HermesVoice.xcodeproj -scheme HermesVoice -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit the header picker**

```bash
git add ios/HermesVoice/HermesVoice/Views/BackendProfileViews.swift ios/HermesVoice/HermesVoice/Views/MainView.swift ios/HermesVoice/HermesVoice.xcodeproj/project.pbxproj
git commit -m "feat: switch servers from main header"
```

## Task 5: Device acceptance and release handoff

**Files:**
- Modify: `docs/superpowers/specs/2026-07-10-server-profiles-design.md` (append verified device results only)

**Interfaces:**
- Consumes the completed profile picker and two independently running laptop backends.
- Produces an on-device verification record; no code changes are needed unless a verified defect is found.

- [ ] **Step 1: Prepare two profile records**

On a physical iPhone, add both laptop backends with their Tailscale/MagicDNS URLs and tokens. Use distinct profile names such as `Studio Mac` and `Laptop` and select different harnesses for each.

- [ ] **Step 2: Verify routing isolation**

Use the header picker to select each laptop in turn. Send a distinct text or voice turn after each selection. Confirm that each backend receives only its own turn, each profile restores its chosen harness, and History and schedules show only data from the selected backend.

- [ ] **Step 3: Verify safety and notifications**

Start a turn and confirm the header picker is unavailable through recording, thinking, and playback. Cancel or complete the turn, then confirm switching works. With notifications enabled, inspect each backend’s device-registration state after selecting it; the cached device token must be registered with the newly active backend.

- [ ] **Step 4: Record results and commit only if documentation changed**

Append only the actual pass/fail results to the design spec. If the results are all passing:

```bash
git add docs/superpowers/specs/2026-07-10-server-profiles-design.md
git commit -m "docs: record server profile device verification"
```

If any check fails, do not claim release readiness; create a focused defect task with reproduction steps and keep this acceptance task open.

## Plan self-review

- **Spec coverage:** Task 1 covers profile data, persistence, migration, active profile access, and per-server harness selection. Task 2 covers conversation reset, onboarding, Watch/shared settings behavior, Siri continuity, and APNs re-registration. Tasks 3–4 cover Settings management, health-gated profile editing, header selection, explicit-only routing, and disabled switching. Task 5 covers the required physical-device isolation and safety checks.
- **Placeholder scan:** no unresolved markers, deferred implementation language, or unspecified verification commands remain.
- **Type consistency:** `BackendProfile`, `AppSettings.activateProfile(id:)`, `ConversationViewModel.switchBackend(to:)`, and `NotificationManager.registerSavedDeviceWithActiveBackendIfNeeded()` are introduced before later tasks consume them.
