import SwiftUI

/// Browse past Hermes conversations. The source of truth is the backend's
/// `/api/sessions` endpoint (which reads Hermes' SQLite store directly).
struct HistoryView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var conversation: ConversationViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var sessions: [HermesVoiceAPI.HistorySession] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                HVColor.bg.ignoresSafeArea()

                ScrollView {
                    if let error {
                        Text(error)
                            .font(HVFont.captionTiny)
                            .foregroundStyle(HVColor.dangerSoft)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                    }

                    if sessions.isEmpty && !loading {
                        emptyState
                    } else {
                        sessionList
                    }
                }
                .scrollIndicators(.hidden)
                .refreshable { await load() }

                if loading && sessions.isEmpty {
                    ProgressView().tint(HVColor.amber).controlSize(.large)
                }
            }
            .navigationTitle("HISTORY")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("HISTORY")
                        .font(HVFont.title)
                        .tracking(0.8)
                        .foregroundStyle(HVColor.amber)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(HVFont.body.weight(.semibold))
                        .foregroundStyle(HVColor.amber)
                }
            }
            .toolbarBackground(HVColor.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .task { await load() }
        }
        .tint(HVColor.amber)
        .preferredColorScheme(.dark)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(HVColor.bronze)
            Text("No conversations yet")
                .font(HVFont.body.weight(.semibold))
                .foregroundStyle(HVColor.cream)
            Text("Talk to your agent from any device and conversations show up here.")
                .font(HVFont.captionTiny)
                .foregroundStyle(HVColor.creamDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .padding(.top, 100)
    }

    private var sessionList: some View {
        VStack(spacing: 0) {
            Text("\(sessions.count) SESSIONS")
                .font(HVFont.captionTiny.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(HVColor.creamDim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

            VStack(spacing: 0) {
                ForEach(Array(sessions.enumerated()), id: \.element.id) { idx, session in
                    NavigationLink {
                        ConversationDetailView(sessionId: session.id)
                            .environmentObject(settings)
                            .environmentObject(conversation)
                    } label: {
                        HistoryRow(session: session)
                    }
                    .buttonStyle(.plain)
                    if idx < sessions.count - 1 {
                        Rectangle().fill(HVColor.hairline).frame(height: 0.5)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12).fill(HVColor.creamSurface)
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let api = HermesVoiceAPI(baseURL: settings.backendURL, authToken: settings.authToken)
        do {
            sessions = try await api.listSessions(limit: 50)
            settings.markReachable()
            error = nil
        } catch {
            self.error = "Couldn't load history: \(error.localizedDescription)"
        }
    }
}

private struct HistoryRow: View {
    let session: HermesVoiceAPI.HistorySession

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(headerTime)
                    .font(HVFont.captionTiny.weight(.semibold))
                    .tracking(1.0)
                    .foregroundStyle(HVColor.bronze)
                Spacer()
                if session.toolCallCount > 0 {
                    Text("⚙ \(session.toolCallCount)")
                        .font(HVFont.micro)
                        .foregroundStyle(HVColor.bronze)
                }
                Text("· \(session.messageCount) msg")
                    .font(HVFont.micro)
                    .foregroundStyle(HVColor.creamDim)
                if session.source == "siri" {
                    Text("SIRI")
                        .font(HVFont.micro.weight(.bold))
                        .tracking(0.6)
                        .foregroundStyle(HVColor.amber)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3).stroke(HVColor.amber, lineWidth: 0.5)
                        )
                }
            }
            HStack(alignment: .top, spacing: 4) {
                Text("›").foregroundStyle(HVColor.amber)
                Text(session.preview)
                    .font(HVFont.bodyDim)
                    .foregroundStyle(HVColor.cream)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var headerTime: String {
        let date = Date(timeIntervalSince1970: session.startedAt)
        let elapsed = Date().timeIntervalSince(date)
        let fmt = DateFormatter()
        if elapsed < 86_400 && Calendar.current.isDateInToday(date) {
            fmt.dateFormat = "h:mm a"
            return "TODAY · \(fmt.string(from: date))"
        }
        if Calendar.current.isDateInYesterday(date) {
            fmt.dateFormat = "h:mm a"
            return "YESTERDAY · \(fmt.string(from: date))"
        }
        fmt.dateFormat = "MMM d · h:mm a"
        return fmt.string(from: date).uppercased()
    }
}
