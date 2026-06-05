import SwiftUI

/// Browse + attach to an existing coding-agent session (Claude Code, etc.).
/// Tapping a session points subsequent voice turns at that harness + session id;
/// the backend resumes it in its original repo — read-only in this phase, so
/// voice can inspect/ask but not edit real code (write-by-voice arrives with the
/// approval layer).
struct SessionBrowserView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var conversation: ConversationViewModel

    let harnessId: String
    let harnessName: String
    /// Called after a successful attach so the presenter can dismiss back to the
    /// live conversation.
    var onAttached: () -> Void

    @State private var sessions: [HermesVoiceAPI.HarnessSession] = []
    @State private var loading = false
    @State private var error = ""
    @State private var writeMode = false
    /// Set when the user taps a large session — drives a confirm-with-remedy
    /// alert instead of attaching straight into a several-minute first reply.
    @State private var pendingHeavy: HermesVoiceAPI.HarnessSession?

    var body: some View {
        List {
            Section {
                Toggle(isOn: $writeMode) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Write mode")
                            .font(HVFont.body)
                            .foregroundStyle(HVColor.cream)
                        Text("Let it edit files + run commands — each change asks for your approval.")
                            .font(HVFont.captionTiny)
                            .foregroundStyle(HVColor.creamDim)
                    }
                }
                .tint(HVColor.amber)
                .listRowBackground(HVColor.creamSurface)
            }
            Section {
                if loading {
                    HStack(spacing: 8) {
                        ProgressView().tint(HVColor.amber)
                        Text("Loading sessions…")
                            .font(HVFont.captionTiny)
                            .foregroundStyle(HVColor.creamDim)
                    }
                    .listRowBackground(HVColor.creamSurface)
                } else if !error.isEmpty {
                    Text(error)
                        .font(HVFont.captionTiny)
                        .foregroundStyle(HVColor.creamDim)
                        .listRowBackground(HVColor.creamSurface)
                } else if sessions.isEmpty {
                    Text("No \(harnessName) sessions found on your Mac yet.")
                        .font(HVFont.captionTiny)
                        .foregroundStyle(HVColor.creamDim)
                        .listRowBackground(HVColor.creamSurface)
                } else {
                    ForEach(sessions) { s in
                        Button { handleTap(s) } label: { row(s) }
                            .listRowBackground(HVColor.creamSurface)
                    }
                }
            } header: {
                Text("\(harnessName.uppercased()) SESSIONS")
            } footer: {
                Text("Continue one of your \(harnessName) sessions by voice. Read-only by default; turn on Write mode to let it edit, with each change gated by an approval card.")
                    .font(HVFont.captionTiny)
                    .foregroundStyle(HVColor.creamDim)
            }
        }
        .scrollContentBackground(.hidden)
        .background(HVColor.bg)
        .navigationTitle("\(harnessName) Sessions")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .alert("Large history", isPresented: heavyAlert, presenting: pendingHeavy) { s in
            Button("Attach anyway") { attach(s) }
            Button("Cancel", role: .cancel) {}
        } message: { s in
            Text("This session has \(s.messageCount) messages, so the first reply may take a few minutes while it loads.\n\nTo speed up future resumes, run /compact in this session's terminal — it shrinks the history while keeping the same session.")
        }
    }

    /// Bridges the optional `pendingHeavy` to the alert's Bool presentation.
    private var heavyAlert: Binding<Bool> {
        Binding(get: { pendingHeavy != nil }, set: { if !$0 { pendingHeavy = nil } })
    }

    private func handleTap(_ s: HermesVoiceAPI.HarnessSession) {
        if s.isHeavy {
            pendingHeavy = s          // confirm + show the /compact remedy first
        } else {
            attach(s)
        }
    }

    private func row(_ s: HermesVoiceAPI.HarnessSession) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(s.repo ?? "session")
                    .font(HVFont.body.weight(.semibold))
                    .foregroundStyle(HVColor.amber)
                Spacer()
                Text(relativeTime(s.startedAt))
                    .font(HVFont.captionTiny)
                    .foregroundStyle(HVColor.creamDim)
            }
            Text(s.displayLabel)
                .font(HVFont.captionTiny)
                .foregroundStyle(HVColor.cream)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text("\(s.messageCount) messages · \(s.toolCallCount) tools")
                .font(HVFont.captionTiny)
                .foregroundStyle(HVColor.creamDim)
            if s.isHeavy { heavyChip(s) }
        }
        .padding(.vertical, 2)
    }

    /// Flags a session whose transcript is large enough that resuming it (a full
    /// replay) makes the first reply slow. Shown before attach so the choice is
    /// informed; the remedy is spelled out in the attach confirmation.
    private func heavyChip(_ s: HermesVoiceAPI.HarnessSession) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("Large · \(s.messageCountLabel) · slow to resume")
        }
        .font(HVFont.captionTiny)
        .foregroundStyle(HVColor.amber)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(HVColor.amber.opacity(0.12), in: Capsule())
        .padding(.top, 1)
    }

    private func attach(_ s: HermesVoiceAPI.HarnessSession) {
        conversation.attach(
            sessionId: s.sessionId, harness: harnessId, repo: s.repo, readOnly: !writeMode
        )
        onAttached()
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let api = HermesVoiceAPI(baseURL: settings.backendURL, authToken: settings.authToken)
        do {
            sessions = try await api.listHarnessSessions(harnessId: harnessId)
            error = ""
        } catch {
            self.error = "Couldn't load sessions (is the backend reachable?)."
        }
    }

    private func relativeTime(_ epoch: Double) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: Date(timeIntervalSince1970: epoch), relativeTo: Date())
    }
}
