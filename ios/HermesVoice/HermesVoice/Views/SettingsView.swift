import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
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

    var body: some View {
        NavigationStack {
            ZStack {
                HVColor.bg.ignoresSafeArea()

                Form {
                    backendSection
                    schedulesSection
                    notificationsSection
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
        }
        .tint(HVColor.amber)
        .preferredColorScheme(.dark)
    }

    private var backendSection: some View {
        Section {
            HVField(label: "URL", value: $draftURL, placeholder: "https://host:8765",
                    onSubmit: { commit() })
            HVField(label: "Token", value: $draftToken, placeholder: "(optional)",
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
            Text("Recurring asks Hermes runs on a cadence (e.g., \"give me the weather\" every 5 minutes). Voice creation (\"every 5 min update me on X\") lands in Phase C.")
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
