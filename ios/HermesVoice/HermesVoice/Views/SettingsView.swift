import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var conversation: ConversationViewModel
    @Environment(\.dismiss) private var dismiss

    // Local mirrors so typing in the URL field doesn't cascade through
    // @Published → UserDefaults.write → view re-render on every keystroke.
    // We commit on submit and on dismiss.
    @State private var draftURL: String = ""
    @State private var draftToken: String = ""
    @State private var hydrated = false

    @State private var healthResult: String = ""
    @State private var pinging = false
    @State private var showSchedules = false
    @State private var voices: [HermesVoiceAPI.VoiceOption] = []
    @State private var voicesLoading = false
    @State private var voicesError = ""

    @State private var harnesses: [HermesVoiceAPI.HarnessOption] = []
    @State private var harnessesLoading = false
    @State private var harnessesError = ""

    @StateObject private var transcriber = LocalTranscriber.shared
    @StateObject private var speaker = LocalSpeaker.shared
    @StateObject private var vad = LocalVad.shared

    var body: some View {
        NavigationStack {
            ZStack {
                HVColor.bg.ignoresSafeArea()

                Form {
                    backendSection
                    harnessSection
                    schedulesSection
                    notificationsSection
                    voiceSection
                    onDeviceVoiceSection
                    transcriptionSection
                    listeningSection
                    modeSection
                    watchSection
                    diagnosticsSection
                }
                .scrollContentBackground(.hidden)
                .background(HVColor.bg)
            }
            .navigationTitle("SETTINGS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("SETTINGS")
                        .font(HVFont.title)
                        .tracking(0.8)
                        .foregroundStyle(HVColor.amber)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        commit()
                        dismiss()
                    }
                    .font(HVFont.body.weight(.semibold))
                    .foregroundStyle(HVColor.amber)
                }
            }
            .toolbarBackground(HVColor.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .onAppear {
                if !hydrated {
                    draftURL = settings.backendURL
                    draftToken = settings.authToken
                    hydrated = true
                }
            }
            .task { await loadVoices() }
            .task { await loadHarnesses() }
        }
        .tint(HVColor.amber)
        .preferredColorScheme(.dark)
    }

    private var backendSection: some View {
        Section {
            HVField(label: "URL", value: $draftURL, placeholder: "https://host:8765",
                    onSubmit: { commit() })
            HVField(label: "Token", value: $draftToken, placeholder: "(required by your backend)",
                    secure: true, onSubmit: { commit() })
            Button {
                Task { await ping() }
            } label: {
                HStack {
                    Text("Ping backend")
                        .font(HVFont.body)
                        .foregroundStyle(HVColor.amber)
                    Spacer()
                    if pinging { ProgressView().tint(HVColor.amber) }
                }
            }
            .listRowBackground(HVColor.amberGlow.opacity(0.5))
        } header: {
            sectionHeader("BACKEND")
        }
    }

    private var schedulesSection: some View {
        Section {
            Button {
                showSchedules = true
            } label: {
                HStack {
                    Text("Manage schedules")
                        .font(HVFont.body)
                        .foregroundStyle(HVColor.cream)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(HVColor.creamDim)
                }
            }
            .listRowBackground(HVColor.creamSurface)
        } header: {
            sectionHeader("RECURRING MESSAGES")
        } footer: {
            Text("Recurring asks your agent runs on a cadence (e.g., \"give me the weather\" every 5 minutes). Voice creation (\"every 5 min update me on X\") lands in Phase C.")
                .font(HVFont.captionTiny)
                .foregroundStyle(HVColor.creamDim)
        }
        .sheet(isPresented: $showSchedules) {
            // Re-inject explicitly: environment objects don't reliably
            // propagate across nested sheet boundaries (Settings is itself
            // a sheet), and SchedulesView hard-requires AppSettings.
            SchedulesView()
                .environmentObject(settings)
        }
    }

    private var notificationsSection: some View {
        Section {
            HVToggleRow(label: "Allow notifications", isOn: $settings.notificationsEnabled)
                .onChange(of: settings.notificationsEnabled) { _, newValue in
                    if newValue {
                        Task {
                            let granted = await NotificationManager.shared.requestAuthorization()
                            if granted {
                                NotificationManager.shared.registerForRemoteNotifications()
                            } else {
                                // User denied at the OS prompt — flip our toggle back
                                // off so the UI matches the system state.
                                await MainActor.run {
                                    settings.notificationsEnabled = false
                                }
                            }
                        }
                    }
                }
            HVToggleRow(
                label: "Auto-play when app is open",
                isOn: $settings.autoPlayScheduledFires
            )
            HVToggleRow(label: "Foreground chime", isOn: $settings.foregroundChimeEnabled)
        } header: {
            sectionHeader("NOTIFICATIONS")
        } footer: {
            Text("Pushes arrive when a schedule fires. \"Auto-play\" replaces the banner with chime + speaker playback while the app is open. Foreground chime can be disabled if you find it noisy.")
                .font(HVFont.captionTiny)
                .foregroundStyle(HVColor.creamDim)
        }
    }

    private var voiceSection: some View {
        Section {
            Picker("Voice", selection: $settings.selectedVoiceId) {
                Text("Default").tag("")
                ForEach(voices) { v in
                    Text(v.name).tag(v.voiceId)
                }
                // On-device Apple voices (always available, no download). Tagged
                // `local:` so the turn speaks the reply on-device instead of via
                // the server.
                if speaker.isReady {
                    ForEach(LocalSpeaker.voices) { v in
                        Text("On-device · \(v.label)").tag("local:\(v.id)")
                    }
                }
            }
            .pickerStyle(.navigationLink)
            .tint(HVColor.amber)
            .listRowBackground(HVColor.creamSurface)
            if voicesLoading {
                HStack(spacing: 8) {
                    ProgressView().tint(HVColor.amber)
                    Text("Loading voices…")
                        .font(HVFont.captionTiny)
                        .foregroundStyle(HVColor.creamDim)
                }
                .listRowBackground(HVColor.creamSurface)
            } else if !voicesError.isEmpty {
                Text(voicesError)
                    .font(HVFont.captionTiny)
                    .foregroundStyle(HVColor.creamDim)
                    .listRowBackground(HVColor.creamSurface)
            }
        } header: {
            sectionHeader("VOICE")
        } footer: {
            Text("ElevenLabs voices from your backend. \"Default\" uses the server's configured voice.")
                .font(HVFont.captionTiny)
                .foregroundStyle(HVColor.creamDim)
        }
    }

    private func loadVoices() async {
        voicesLoading = true
        defer { voicesLoading = false }
        let api = HermesVoiceAPI(baseURL: settings.backendURL, authToken: settings.authToken)
        do {
            voices = try await api.listVoices()
            voicesError = ""
        } catch let HermesVoiceAPI.APIError.httpStatus(code, _) where code == 401 {
            voicesError = "Auth token required — add it under Backend above."
        } catch {
            voicesError = "Couldn't load voices (is the backend reachable?)."
        }
    }

    private var harnessSection: some View {
        Section {
            Picker("Agent", selection: $settings.selectedHarness) {
                ForEach(harnesses) { h in
                    Text(h.available ? h.name : "\(h.name) (unavailable)")
                        .tag(h.harnessId)
                }
            }
            .pickerStyle(.navigationLink)
            .tint(HVColor.amber)
            .listRowBackground(HVColor.creamSurface)
            if harnessesLoading {
                HStack(spacing: 8) {
                    ProgressView().tint(HVColor.amber)
                    Text("Loading agents…")
                        .font(HVFont.captionTiny)
                        .foregroundStyle(HVColor.creamDim)
                }
                .listRowBackground(HVColor.creamSurface)
            } else if !harnessesError.isEmpty {
                Text(harnessesError)
                    .font(HVFont.captionTiny)
                    .foregroundStyle(HVColor.creamDim)
                    .listRowBackground(HVColor.creamSurface)
            }
            if isCodingHarness(settings.selectedHarness) {
                NavigationLink {
                    SessionBrowserView(
                        harnessId: settings.selectedHarness,
                        harnessName: harnessDisplayName(settings.selectedHarness),
                        onAttached: { dismiss() }
                    )
                    .environmentObject(settings)
                    .environmentObject(conversation)
                } label: {
                    Label("Attach to a session", systemImage: "link")
                        .font(HVFont.body)
                        .foregroundStyle(HVColor.cream)
                }
                .tint(HVColor.amber)
                .listRowBackground(HVColor.creamSurface)
            }
        } header: {
            sectionHeader("AGENT")
        } footer: {
            Text("Which agent answers your turns. Hermes is the default; Claude Code, Codex, and OpenCode run in a shared workspace on your Mac.")
                .font(HVFont.captionTiny)
                .foregroundStyle(HVColor.creamDim)
        }
    }

    private func loadHarnesses() async {
        harnessesLoading = true
        defer { harnessesLoading = false }
        let api = HermesVoiceAPI(baseURL: settings.backendURL, authToken: settings.authToken)
        do {
            harnesses = try await api.listHarnesses()
            harnessesError = ""
            // If the persisted selection is no longer offered (e.g. a CLI was
            // uninstalled), fall back to the first available agent.
            if !harnesses.isEmpty,
               !harnesses.contains(where: { $0.harnessId == settings.selectedHarness && $0.available }) {
                if let fallback = harnesses.first(where: { $0.available }) ?? harnesses.first {
                    settings.selectedHarness = fallback.harnessId
                }
            }
        } catch let HermesVoiceAPI.APIError.httpStatus(code, _) where code == 401 {
            harnessesError = "Auth token required — add it under Backend above."
        } catch {
            harnessesError = "Couldn't load agents (is the backend reachable?)."
        }
    }

    private func isCodingHarness(_ id: String) -> Bool {
        ["claude", "codex", "opencode"].contains(id)
    }

    private func harnessDisplayName(_ id: String) -> String {
        harnesses.first(where: { $0.harnessId == id })?.name ?? id.capitalized
    }

    @ViewBuilder
    private var onDeviceVoiceSection: some View {
        Section {
            HVKVRow(label: "Voice engine", value: "Apple · on-device", accent: HVColor.amber)
            if settings.isLocalVoiceSelected,
               let note = LocalSpeaker.unavailableGenderNote(for: settings.localVoiceName) {
                Text(note)
                    .font(HVFont.captionTiny)
                    .foregroundStyle(HVColor.bronze)
                    .listRowBackground(HVColor.creamSurface)
            }
            // Spoken filler only operates on the on-device voice path, so only
            // surface the control when an on-device voice is selected.
            if settings.isLocalVoiceSelected {
                Picker("Spoken updates", selection: $settings.fillerVerbosity) {
                    ForEach(FillerVerbosity.allCases) { v in
                        Text(v.label).tag(v)
                    }
                }
                .pickerStyle(.navigationLink)
                .tint(HVColor.amber)
                .listRowBackground(HVColor.creamSurface)
                Text("How much Harness talks while it works.")
                    .font(HVFont.captionTiny)
                    .foregroundStyle(HVColor.creamDim)
                    .listRowBackground(HVColor.creamSurface)
            }
        } header: {
            sectionHeader("ON-DEVICE VOICE")
        } footer: {
            Text("Speak replies on this iPhone with Apple's built-in voices — no cloud round-trip, no download. Pick an \"On-device\" voice above. Server (ElevenLabs) voices keep working.")
                .font(HVFont.captionTiny)
                .foregroundStyle(HVColor.creamDim)
        }
    }

    @ViewBuilder
    private var transcriptionSection: some View {
        Section {
            switch transcriber.state {
            case .notDownloaded:
                Button {
                    Task { await transcriber.prepare() }
                } label: {
                    HStack {
                        Text("Download model (~450 MB)")
                            .font(HVFont.body)
                            .foregroundStyle(HVColor.amber)
                        Spacer()
                        Image(systemName: "arrow.down.circle")
                            .foregroundStyle(HVColor.amber)
                    }
                }
                .listRowBackground(HVColor.amberGlow.opacity(0.5))
            case .downloading:
                HStack(spacing: 8) {
                    ProgressView().tint(HVColor.amber)
                    Text("Downloading parakeet-v2…")
                        .font(HVFont.body)
                        .foregroundStyle(HVColor.cream)
                }
                .listRowBackground(HVColor.creamSurface)
            case .ready:
                HVToggleRow(label: "Transcribe on device", isOn: $settings.useOnDeviceSTT)
                HVKVRow(label: "Model", value: "parakeet-v2 · ready", accent: HVColor.amber)
                Button {
                    transcriber.deleteModel()
                } label: {
                    Text("Remove model")
                        .font(HVFont.body)
                        .foregroundStyle(HVColor.bronze)
                }
                .listRowBackground(HVColor.creamSurface)
            case .failed(let msg):
                Text(msg)
                    .font(HVFont.captionTiny)
                    .foregroundStyle(HVColor.bronze)
                    .listRowBackground(HVColor.creamSurface)
                Button {
                    Task { await transcriber.prepare() }
                } label: {
                    Text("Retry download")
                        .font(HVFont.body)
                        .foregroundStyle(HVColor.amber)
                }
                .listRowBackground(HVColor.amberGlow.opacity(0.5))
            }
        } header: {
            sectionHeader("ON-DEVICE TRANSCRIPTION")
        } footer: {
            Text("Runs parakeet-v2 on this iPhone — your audio never leaves the device and there's no upload wait. Downloaded once (~450 MB) and cached on-device. When off, or before download, mic turns upload audio for server transcription instead.")
                .font(HVFont.captionTiny)
                .foregroundStyle(HVColor.creamDim)
        }
    }

    @ViewBuilder
    private var listeningSection: some View {
        Section {
            switch vad.state {
            case .notDownloaded:
                Button {
                    Task { await vad.prepare() }
                } label: {
                    HStack {
                        Text("Download listening model")
                            .font(HVFont.body)
                            .foregroundStyle(HVColor.amber)
                        Spacer()
                        Image(systemName: "arrow.down.circle")
                            .foregroundStyle(HVColor.amber)
                    }
                }
                .listRowBackground(HVColor.amberGlow.opacity(0.5))
            case .downloading:
                HStack(spacing: 8) {
                    ProgressView().tint(HVColor.amber)
                    Text("Downloading VAD…")
                        .font(HVFont.body)
                        .foregroundStyle(HVColor.cream)
                }
                .listRowBackground(HVColor.creamSurface)
            case .ready:
                HVKVRow(label: "Listening model", value: "Silero VAD · ready", accent: HVColor.amber)
            case .failed(let msg):
                Text(msg)
                    .font(HVFont.captionTiny)
                    .foregroundStyle(HVColor.bronze)
                    .listRowBackground(HVColor.creamSurface)
                Button {
                    Task { await vad.prepare() }
                } label: {
                    Text("Retry download")
                        .font(HVFont.body)
                        .foregroundStyle(HVColor.amber)
                }
                .listRowBackground(HVColor.amberGlow.opacity(0.5))
            }
        } header: {
            sectionHeader("HANDS-FREE LISTENING (VAD)")
        } footer: {
            Text("Powers hands-free conversation mode (the speech-bubble button in the top bar): detects when you've finished talking, on-device. Download once. Needs an on-device voice (Kokoro) for the reply.")
                .font(HVFont.captionTiny)
                .foregroundStyle(HVColor.creamDim)
        }
    }

    private var modeSection: some View {
        Section {
            Picker("", selection: $settings.mode) {
                ForEach(AppSettings.Mode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .listRowBackground(HVColor.creamSurface)
        } header: {
            sectionHeader("INPUT MODE")
        }
    }

    private var watchSection: some View {
        Section {
            HVToggleRow(label: "Play replies on Watch", isOn: $settings.playReplyOnWatch)
        } header: {
            sectionHeader("APPLE WATCH")
        } footer: {
            Text("When on, voice replies play through the Watch speaker. iPhone downloads the audio first, so playback starts slightly later than on iPhone.")
                .font(HVFont.captionTiny)
                .foregroundStyle(HVColor.creamDim)
        }
    }

    private var diagnosticsSection: some View {
        Section {
            HVKVRow(label: "Last seen", value: lastSeenLabel,
                    accent: lastSeenIsStale ? HVColor.bronze : HVColor.amber)
            HVKVRow(label: "Build", value: Self.buildInfo)
            HVKVRow(label: "ATS", value: Self.atsInfo)
            if !healthResult.isEmpty {
                Text(healthResult)
                    .font(HVFont.captionTiny)
                    .foregroundStyle(HVColor.creamDim)
                    .textSelection(.enabled)
                    .listRowBackground(HVColor.creamSurface)
            }
        } header: {
            sectionHeader("DIAGNOSTICS")
        } footer: {
            Text("Logs are local; never sent off-device.")
                .font(HVFont.captionTiny)
                .foregroundStyle(HVColor.creamDim)
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(HVFont.captionTiny.weight(.semibold))
            .tracking(1.2)
            .foregroundStyle(HVColor.bronze)
    }

    private var lastSeenLabel: String {
        guard let date = settings.lastReachable else { return "never" }
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 60 { return "just now" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m ago" }
        if elapsed < 86_400 { return "\(Int(elapsed / 3600))h ago" }
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d, HH:mm"
        return fmt.string(from: date)
    }

    private var lastSeenIsStale: Bool {
        guard let date = settings.lastReachable else { return true }
        return Date().timeIntervalSince(date) > 600
    }

    private func commit() {
        let trimmed = draftURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != settings.backendURL { settings.backendURL = trimmed }
        if draftToken != settings.authToken { settings.authToken = draftToken }
    }

    private static let buildInfo: String = {
        guard let exe = Bundle.main.executableURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: exe.path),
              let date = attrs[.modificationDate] as? Date
        else { return "unknown" }
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm:ss"
        return fmt.string(from: date)
    }()

    private static let atsInfo: String = {
        guard let ats = Bundle.main.infoDictionary?["NSAppTransportSecurity"] as? [String: Any] else {
            return "default (strict)"
        }
        let arb = (ats["NSAllowsArbitraryLoads"] as? Bool) ?? false
        let local = (ats["NSAllowsLocalNetworking"] as? Bool) ?? false
        if arb { return "fully open (arbitrary)" }
        if local { return "local only" }
        return "configured but restrictive"
    }()

    private func ping() async {
        commit()
        pinging = true
        defer { pinging = false }
        let api = HermesVoiceAPI(baseURL: settings.backendURL, authToken: settings.authToken)
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

// MARK: - Brand-styled form rows

private struct HVField: View {
    let label: String
    @Binding var value: String
    var placeholder: String = ""
    var secure: Bool = false
    var onSubmit: () -> Void = {}

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
                    .onSubmit(onSubmit)
            } else {
                TextField(placeholder, text: $value)
                    .font(HVFont.body)
                    .foregroundStyle(HVColor.cream)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onSubmit(onSubmit)
            }
        }
        .listRowBackground(HVColor.creamSurface)
    }
}

private struct HVToggleRow: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(label)
                .font(HVFont.body)
                .foregroundStyle(HVColor.cream)
        }
        .tint(HVColor.amber)
        .listRowBackground(HVColor.creamSurface)
    }
}

private struct HVKVRow: View {
    let label: String
    let value: String
    var accent: Color = HVColor.creamDim

    var body: some View {
        HStack {
            Text(label)
                .font(HVFont.bodyDim)
                .foregroundStyle(HVColor.creamDim)
            Spacer()
            Text(value)
                .font(HVFont.caption.monospacedDigit())
                .foregroundStyle(accent)
        }
        .listRowBackground(HVColor.creamSurface)
    }
}
