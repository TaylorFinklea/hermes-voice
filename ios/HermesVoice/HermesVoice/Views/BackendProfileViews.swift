import SwiftUI

/// Shared backend-routing apply path. Every UI that can change active routing —
/// the main-header picker, the editor's active-profile save, and the Settings
/// Agent picker — funnels its eligibility check and post-apply side effects
/// through here, so the gate and the cross-device continuity invalidation can't
/// drift between call sites.
enum BackendRouting {
    /// The single composite eligibility predicate. A routing change is allowed
    /// only when the conversation is at rest (`canSwitchBackend`), hands-free
    /// conversation mode isn't running, and no Watch relay is in flight — any of
    /// those would be stranded or wrongly rerouted by a switch.
    @MainActor
    static func canApply(
        conversation: ConversationViewModel,
        conversationMode: ConversationModeController,
        watchBridge: PhoneWatchBridge
    ) -> Bool {
        conversation.canSwitchBackend && !conversationMode.isActive && !watchBridge.isRelaying
    }

    /// The single post-apply orchestration run on every routing-affecting apply.
    /// `previous` is the pre-change profile snapshot; `endpointChanged` is true
    /// only when the url or token changed (which alone drives the active-only
    /// APNs handoff). Cross-device continuity (Siri session + Watch relay marker)
    /// is invalidated on ANY routing-affecting apply — including a same-profile
    /// harness-only change, where the profile UUID is unchanged but the agent
    /// (and thus the conversation) is not the one those markers were created for.
    @MainActor
    static func applySideEffects(previous: BackendProfile, endpointChanged: Bool) {
        let notifications = NotificationManager.shared
        notifications.clearArrival()
        notifications.stopForegroundPlayback()
        if endpointChanged {
            notifications.handleBackendSwitch(previous: previous)
        }
        SiriSession.clear()
        PhoneWatchBridge.shared.clearRelayMarker()
    }
}

/// The main-header control for switching the active backend profile. Renders
/// the existing agent title on top (unchanged from the old static header)
/// with the active server's name + a chevron beneath it — the whole thing is
/// one accessible button that opens a menu of every saved profile plus
/// "Manage servers…". Disabled (and thus unopenable) whenever `canSwitch` is
/// false, so a live turn / hands-free session / Watch relay can never be
/// interrupted by a switch.
struct BackendProfilePicker: View {
    @EnvironmentObject var settings: AppSettings
    let canSwitch: Bool
    let select: (BackendProfile) -> Void
    let manage: () -> Void

    var body: some View {
        Menu {
            ForEach(settings.backendProfiles) { profile in
                Button {
                    select(profile)
                } label: {
                    if profile.id == settings.activeBackendProfile.id {
                        Label(profile.name, systemImage: "checkmark")
                    } else {
                        Text(profile.name)
                    }
                }
            }
            Divider()
            Button(action: manage) {
                Text("Manage servers…")
            }
        } label: {
            VStack(spacing: 2) {
                Text(settings.activeAgentTitle)
                    .font(HVFont.title)
                    .tracking(0.8)
                    .foregroundStyle(settings.agentAccent)
                HStack(spacing: 3) {
                    Text(settings.activeBackendProfile.name)
                        .font(HVFont.micro)
                        .tracking(0.4)
                        .foregroundStyle(HVColor.creamDim)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(HVColor.creamDim)
                }
            }
        }
        .disabled(!canSwitch)
        .accessibilityLabel("Active server: \(settings.activeBackendProfile.name)")
        .accessibilityHint(canSwitch ? "" : "Finish or cancel the current turn, hands-free session, or Watch activity before switching servers.")
    }
}

/// Lists every saved backend connection, opens the editor for add/edit, and
/// exposes deletion where the model allows it. Selecting/activating a profile
/// is NOT this view's job — that's the header picker (Task 4). This view also
/// owns the active-server reachability ping that used to live directly in
/// `SettingsView`.
struct BackendProfileManagerView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var conversation: ConversationViewModel
    @EnvironmentObject var conversationMode: ConversationModeController

    @State private var editingProfile: BackendProfile?
    @State private var showingAdd = false
    @State private var pinging = false
    @State private var healthResult = ""

    var body: some View {
        List {
            Section {
                ForEach(settings.backendProfiles) { profile in
                    Button {
                        editingProfile = profile
                    } label: {
                        row(for: profile)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(HVColor.creamSurface)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if canDelete(profile) {
                            Button(role: .destructive) {
                                settings.removeProfile(id: profile.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                sectionHeader("SAVED SERVERS")
            } footer: {
                Text("Tap a server to edit its URL, token, or agent. The active server and your only saved server can't be deleted.")
                    .font(HVFont.captionTiny)
                    .foregroundStyle(HVColor.creamDim)
            }

            Section {
                pingRow
                if !healthResult.isEmpty {
                    Text(healthResult)
                        .font(HVFont.captionTiny)
                        .foregroundStyle(HVColor.creamDim)
                        .textSelection(.enabled)
                        .listRowBackground(HVColor.creamSurface)
                }
            } header: {
                sectionHeader("ACTIVE SERVER")
            } footer: {
                Text("Pings \(settings.activeBackendProfile.name) directly. Reachability only — it doesn't validate the saved token.")
                    .font(HVFont.captionTiny)
                    .foregroundStyle(HVColor.creamDim)
            }
        }
        .scrollContentBackground(.hidden)
        .background(HVColor.bg)
        .navigationTitle("SERVERS")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAdd = true
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(HVColor.amber)
                }
                .accessibilityLabel("Add server")
            }
        }
        .sheet(isPresented: $showingAdd) {
            BackendProfileEditorView(existingProfile: nil, onSaved: { _ in })
                .environmentObject(settings)
                .environmentObject(conversation)
                .environmentObject(conversationMode)
        }
        .sheet(item: $editingProfile) { profile in
            BackendProfileEditorView(existingProfile: profile, onSaved: { _ in })
                .environmentObject(settings)
                .environmentObject(conversation)
                .environmentObject(conversationMode)
        }
    }

    private func row(for profile: BackendProfile) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(HVFont.body)
                    .foregroundStyle(HVColor.cream)
                Text(profile.url)
                    .font(HVFont.captionTiny)
                    .foregroundStyle(HVColor.creamDim)
                    .lineLimit(1)
            }
            Spacer()
            if profile.id == settings.activeBackendProfile.id {
                Text("ACTIVE")
                    .font(HVFont.chipTiny)
                    .foregroundStyle(HVColor.bg)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(HVColor.amber, in: Capsule())
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(HVColor.creamDim)
        }
        .padding(.vertical, 2)
    }

    private var pingRow: some View {
        Button {
            Task { await pingActive() }
        } label: {
            HStack {
                Text("Ping \(settings.activeBackendProfile.name)")
                    .font(HVFont.body)
                    .foregroundStyle(HVColor.amber)
                Spacer()
                if pinging { ProgressView().tint(HVColor.amber) }
            }
        }
        .listRowBackground(HVColor.amberGlow.opacity(0.5))
    }

    /// Mirrors the model's own guard (`AppSettings.removeProfile`) so the UI
    /// never offers an action the model would refuse anyway.
    private func canDelete(_ profile: BackendProfile) -> Bool {
        profile.id != settings.activeBackendProfile.id && settings.backendProfiles.count > 1
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(HVFont.captionTiny.weight(.semibold))
            .tracking(1.2)
            .foregroundStyle(HVColor.bronze)
    }

    private func pingActive() async {
        pinging = true
        defer { pinging = false }
        let profile = settings.activeBackendProfile
        let api = HermesVoiceAPI(baseURL: profile.url, authToken: profile.authToken)
        do {
            let json = try await api.health()
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
            healthResult = String(data: data, encoding: .utf8) ?? "<empty>"
            settings.markReachable()
        } catch {
            healthResult = "Error: \(error.localizedDescription)"
        }
    }
}

/// Add/edit a single backend profile. Keeps everything in local `@State`
/// drafts until an authenticated `/api/harnesses` check passes — that check
/// both validates the URL/token and supplies the harness picker's options.
/// Saving an edit to the ACTIVE profile additionally requires the
/// conversation to be at rest, and routes the credential change through
/// `ConversationViewModel.switchBackend(to:)` (same teardown as a real
/// switch) rather than mutating settings directly.
struct BackendProfileEditorView: View {
    let existingProfile: BackendProfile?
    let onSaved: (BackendProfile) -> Void

    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var conversation: ConversationViewModel
    @EnvironmentObject var conversationMode: ConversationModeController
    @StateObject private var watchBridge = PhoneWatchBridge.shared
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var url = ""
    @State private var token = ""
    @State private var selectedHarness = ""

    @State private var harnesses: [HermesVoiceAPI.HarnessOption] = []
    @State private var testing = false
    @State private var testError: String?

    // The exact name/URL/token that passed the latest check. Any edit to
    // name, URL, or token makes `checkPassed` false again (it compares
    // against the CURRENT draft), so a rename alone requires re-testing —
    // deliberate, not an oversight: the check is a snapshot of the whole
    // draft, not just the network-relevant fields.
    @State private var passedName: String?
    @State private var passedURL: String?
    @State private var passedToken: String?

    @State private var saving = false
    @State private var saveError: String?
    @State private var hydrated = false

    var body: some View {
        NavigationStack {
            ZStack {
                HVColor.bg.ignoresSafeArea()
                Form {
                    Section {
                        BackendField(label: "Name", value: $name,
                                     placeholder: BackendProfile.suggestedName(for: url))
                        BackendField(label: "URL", value: $url, placeholder: "https://host:8765",
                                     keyboardType: .URL)
                        BackendField(label: "Token", value: $token,
                                     placeholder: "(required by your backend)", secure: true)
                    } header: {
                        sectionHeader("SERVER")
                    }

                    Section {
                        Button {
                            Task { await test() }
                        } label: {
                            HStack {
                                Text("Test connection")
                                    .font(HVFont.body)
                                    .foregroundStyle(HVColor.amber)
                                Spacer()
                                if testing {
                                    ProgressView().tint(HVColor.amber)
                                } else if checkPassed {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(HVColor.amber)
                                }
                            }
                        }
                        .disabled(testing || trimmedURL.isEmpty)
                        .listRowBackground(HVColor.amberGlow.opacity(0.5))
                        if let testError {
                            Text(testError)
                                .font(HVFont.captionTiny)
                                .foregroundStyle(HVColor.dangerSoft)
                                .listRowBackground(HVColor.creamSurface)
                        } else if checkPassed {
                            Text("Connected — \(harnesses.count) agent\(harnesses.count == 1 ? "" : "s") available.")
                                .font(HVFont.captionTiny)
                                .foregroundStyle(HVColor.creamDim)
                                .listRowBackground(HVColor.creamSurface)
                        }
                    } header: {
                        sectionHeader("CONNECTION")
                    } footer: {
                        Text("Validates the URL and token against your backend (the same authenticated call the Agent picker uses) and loads its available agents.")
                            .font(HVFont.captionTiny)
                            .foregroundStyle(HVColor.creamDim)
                    }

                    if checkPassed && !harnesses.isEmpty {
                        Section {
                            Picker("Agent", selection: $selectedHarness) {
                                ForEach(harnesses) { h in
                                    Text(h.available ? h.name : "\(h.name) (unavailable)")
                                        .tag(h.harnessId)
                                }
                            }
                            .pickerStyle(.navigationLink)
                            .tint(HVColor.amber)
                            .listRowBackground(HVColor.creamSurface)
                        } header: {
                            sectionHeader("AGENT")
                        }
                    }

                    if routingChanged && !eligibleToApply {
                        Section {
                            Text("A turn, hands-free session, or Watch relay is in progress on the active server. Finish or cancel it before saving routing changes here.")
                                .font(HVFont.captionTiny)
                                .foregroundStyle(HVColor.bronze)
                                .listRowBackground(HVColor.creamSurface)
                        }
                    }

                    if let saveError {
                        Section {
                            Text(saveError)
                                .font(HVFont.captionTiny)
                                .foregroundStyle(HVColor.dangerSoft)
                                .listRowBackground(HVColor.danger.opacity(0.08))
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .background(HVColor.bg)
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(navTitle)
                        .font(HVFont.title)
                        .tracking(0.8)
                        .foregroundStyle(HVColor.amber)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .font(HVFont.body)
                        .foregroundStyle(HVColor.creamDim)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await save() }
                    } label: {
                        if saving {
                            ProgressView().tint(HVColor.amber)
                        } else {
                            Text("Save")
                                .font(HVFont.body.weight(.semibold))
                                .foregroundStyle(canSave ? HVColor.amber : HVColor.creamFaint)
                        }
                    }
                    .disabled(!canSave)
                    .accessibilityHint(saveDisabledHint)
                }
            }
            .toolbarBackground(HVColor.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .onAppear { hydrate() }
        }
        .tint(HVColor.amber)
        .preferredColorScheme(.dark)
    }

    private var navTitle: String {
        existingProfile == nil ? "ADD SERVER" : "EDIT SERVER"
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedURL: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// True once the CURRENT draft (name, URL, token) exactly matches the
    /// draft that last passed `listHarnesses()`. Changing any of the three
    /// makes this false again, which both disables Save and hides the
    /// harness picker's now-stale options.
    private var checkPassed: Bool {
        passedName == trimmedName && passedURL == trimmedURL && passedToken == token
    }

    private var isActiveProfile: Bool {
        existingProfile?.id == settings.activeBackendProfile.id
    }

    /// The harness that will be persisted: the picked one, or (when the picker
    /// was never touched) the existing profile's harness.
    private var effectiveHarness: String {
        selectedHarness.isEmpty ? (existingProfile?.selectedHarness ?? "") : selectedHarness
    }

    /// True when this edit changes the active profile's endpoint (url or token).
    /// Only an endpoint change drives the active-only APNs handoff.
    private var endpointChanged: Bool {
        guard isActiveProfile, let existingProfile else { return false }
        return trimmedURL != existingProfile.url || token != existingProfile.authToken
    }

    /// True when this edit changes the active profile's harness (agent).
    private var harnessChanged: Bool {
        guard isActiveProfile, let existingProfile else { return false }
        return effectiveHarness != existingProfile.selectedHarness
    }

    /// A routing-affecting edit to the ACTIVE profile: endpoint OR harness
    /// changed. These require the gate + switch teardown + orchestration; a
    /// name-only change (or any edit to a non-active profile) does not.
    private var routingChanged: Bool { endpointChanged || harnessChanged }

    /// The shared composite gate (conversation at rest, no hands-free, no Watch
    /// relay), evaluated the same way as the header picker and Agent picker.
    private var eligibleToApply: Bool {
        BackendRouting.canApply(
            conversation: conversation,
            conversationMode: conversationMode,
            watchBridge: watchBridge
        )
    }

    private var canSave: Bool {
        // Name may be blank — it auto-fills from the URL host at save (E1).
        // URL + a passed connection check stay required. Routing-affecting
        // edits to the active profile additionally require the composite gate.
        !trimmedURL.isEmpty && checkPassed && !saving
            && (!routingChanged || eligibleToApply)
    }

    private var saveDisabledHint: String {
        guard routingChanged, !eligibleToApply else { return "" }
        return "Finish or cancel the current turn, hands-free session, or Watch activity before saving routing changes to the active server."
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(HVFont.captionTiny.weight(.semibold))
            .tracking(1.2)
            .foregroundStyle(HVColor.bronze)
    }

    private func hydrate() {
        // The Agent picker is `.navigationLink`-style, so popping back from it
        // re-fires the editor's `.onAppear` — without this guard that re-appear
        // would silently revert in-progress edits (and the just-picked harness)
        // to the stored profile.
        guard !hydrated else { return }
        hydrated = true
        guard let existingProfile else { return }
        name = existingProfile.name
        url = existingProfile.url
        token = existingProfile.authToken
        selectedHarness = existingProfile.selectedHarness
    }

    private func test() async {
        testing = true
        testError = nil
        defer { testing = false }
        let trimmed = trimmedURL
        let api = HermesVoiceAPI(baseURL: trimmed, authToken: token)
        do {
            let result = try await api.listHarnesses()
            harnesses = result
            if !result.contains(where: { $0.harnessId == selectedHarness }) {
                selectedHarness = result.first?.harnessId ?? ""
            }
            passedName = trimmedName
            passedURL = trimmed
            passedToken = token
        } catch {
            testError = error.localizedDescription
            harnesses = []
            passedName = nil
            passedURL = nil
            passedToken = nil
        }
    }

    private func save() async {
        guard canSave else { return }
        saving = true
        saveError = nil
        defer { saving = false }
        // Name defaults from the URL host when left blank (E1); `saveProfile`
        // applies the same fallback, but resolve here so `onSaved` sees it too.
        let resolvedName = trimmedName.isEmpty
            ? BackendProfile.suggestedName(for: trimmedURL)
            : trimmedName
        let profile = BackendProfile(
            id: existingProfile?.id ?? UUID(),
            name: resolvedName,
            url: trimmedURL,
            authToken: token,
            selectedHarness: effectiveHarness
        )

        if routingChanged {
            // Routing-affecting edit to the ACTIVE profile. Snapshot the
            // pre-change profile BEFORE saveProfile mutates it, persist, then
            // route through switchBackend (same id → stale-turn cancel +
            // conversation reset + lastReachable clear) and the shared
            // orchestration. `endpointChanged` gates the APNs handoff; a
            // harness-only change still invalidates cross-device continuity.
            let previous = settings.activeBackendProfile
            settings.saveProfile(profile)
            guard conversation.switchBackend(to: profile.id) else {
                saveError = "Saved, but couldn't apply — a turn just started. Try Save again."
                return
            }
            BackendRouting.applySideEffects(previous: previous, endpointChanged: endpointChanged)
        } else {
            // Name-only change, or any edit to a non-active profile: a plain
            // save with no reset and no orchestration.
            settings.saveProfile(profile)
        }
        onSaved(profile)
        dismiss()
    }
}

// MARK: - Brand-styled form row

private struct BackendField: View {
    let label: String
    @Binding var value: String
    var placeholder: String = ""
    var secure: Bool = false
    var keyboardType: UIKeyboardType = .default

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(HVFont.bodyDim)
                .foregroundStyle(HVColor.creamDim)
                .frame(width: 60, alignment: .leading)
            if secure {
                SecureField(placeholder, text: $value)
                    .font(HVFont.body)
                    .foregroundStyle(HVColor.cream)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } else {
                TextField(placeholder, text: $value)
                    .font(HVFont.body)
                    .foregroundStyle(HVColor.cream)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(keyboardType)
            }
        }
        .listRowBackground(HVColor.creamSurface)
    }
}
