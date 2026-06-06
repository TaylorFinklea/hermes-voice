import SwiftUI

/// Shows a single past conversation in full — user messages, tool-call audit
/// rows, assistant replies. Each assistant message has a Replay button that
/// re-synthesizes the same text via ElevenLabs.
struct ConversationDetailView: View {
    let sessionId: String

    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var conversation: ConversationViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var detail: HermesVoiceAPI.HistoryDetail?
    @State private var loading = true
    @State private var error: String?

    @State private var player = AudioPlayer()
    @State private var replayingMessageId: String?

    var body: some View {
        ZStack {
            HVColor.bg.ignoresSafeArea()

            if let detail {
                content(detail)
            } else if loading {
                ProgressView().tint(HVColor.amber).controlSize(.large)
            } else if let error {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32))
                        .foregroundStyle(HVColor.bronze)
                    Text("Couldn't load")
                        .font(HVFont.body.weight(.semibold))
                        .foregroundStyle(HVColor.cream)
                    Text(error)
                        .font(HVFont.captionTiny)
                        .foregroundStyle(HVColor.creamDim)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("CONVERSATION")
                    .font(HVFont.title)
                    .tracking(0.8)
                    .foregroundStyle(HVColor.amber)
            }
            if let detail, !detail.messages.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        conversation.resume(sessionId: detail.sessionId)
                        dismiss()
                    } label: {
                        HStack(spacing: 4) {
                            Text("Continue").font(HVFont.captionTiny.weight(.semibold))
                            Image(systemName: "arrow.right.circle.fill")
                        }
                        .foregroundStyle(HVColor.amber)
                    }
                }
            }
        }
        .toolbarBackground(HVColor.bg, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await load() }
        .onDisappear { player.stop() }
    }

    private func content(_ detail: HermesVoiceAPI.HistoryDetail) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(detail.messages) { msg in
                    MessageRow(
                        message: msg,
                        isReplaying: replayingMessageId == msg.id,
                        onReplay: { Task { await replay(msg) } }
                    )
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .scrollIndicators(.hidden)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let api = HermesVoiceAPI(baseURL: settings.backendURL, authToken: settings.authToken)
        do {
            detail = try await api.getSession(id: sessionId)
            settings.markReachable()
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func replay(_ message: HermesVoiceAPI.HistoryMessage) async {
        guard message.role == "assistant", !message.text.isEmpty else { return }
        replayingMessageId = message.id
        defer { replayingMessageId = nil }
        let api = HermesVoiceAPI(baseURL: settings.backendURL, authToken: settings.authToken)
        do {
            let path = try await api.replayAudio(text: message.text, voiceId: settings.selectedVoiceId)
            guard let url = api.makeURL(path: path) else { return }
            await player.play(url: url, authToken: settings.authToken)
        } catch {
            self.error = "Replay failed: \(error.localizedDescription)"
        }
    }
}

private struct MessageRow: View {
    let message: HermesVoiceAPI.HistoryMessage
    let isReplaying: Bool
    let onReplay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch message.role {
            case "user":
                HStack(alignment: .top, spacing: 4) {
                    Text("›").foregroundStyle(HVColor.amber).font(HVFont.heroUser)
                    Text(message.text)
                        .font(HVFont.heroUser)
                        .foregroundStyle(HVColor.cream)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case "assistant":
                HStack(alignment: .top, spacing: 4) {
                    Text("←").foregroundStyle(HVColor.gold).font(HVFont.heroReply)
                    MarkdownText(markdown: message.text, bodyFont: HVFont.heroReply, color: HVColor.cream)
                        .textSelection(.enabled)
                }
                if !message.text.isEmpty {
                    Button(action: onReplay) {
                        HStack(spacing: 5) {
                            Image(systemName: isReplaying ? "speaker.wave.2.fill" : "play.circle")
                                .font(.system(size: 11, weight: .semibold))
                            Text(isReplaying ? "Playing…" : "Replay")
                                .font(HVFont.micro.weight(.semibold))
                                .tracking(0.6)
                        }
                        .foregroundStyle(HVColor.gold)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(HVColor.goldGlow.opacity(0.4))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isReplaying)
                    .padding(.leading, 16)
                }
            case "tool":
                ToolChip(
                    name: message.toolName ?? "tool",
                    preview: message.text.replacingOccurrences(of: "\n", with: " ")
                )
            default:
                EmptyView()
            }

            if !message.toolCalls.isEmpty {
                VStack(spacing: 4) {
                    ForEach(Array(message.toolCalls.enumerated()), id: \.offset) { _, tc in
                        ToolChip(name: tc.name, preview: tc.argumentsPreview)
                    }
                }
            }
        }
    }
}
