import SwiftUI

struct MainView: View {
    @EnvironmentObject var conversation: ConversationViewModel
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var conversationMode: ConversationModeController
    @StateObject private var notifications = NotificationManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var activeSheet: ActiveSheet?
    @State private var textInput = ""
    @State private var typingMode = false

    // One sheet at a time. Multiple `.sheet(isPresented:)` modifiers stacked on
    // a single view shadow each other (History stopped opening once the
    // transcript sheet was added) — so route them all through one `.sheet(item:)`.
    private enum ActiveSheet: String, Identifiable {
        case settings, history, transcript
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                HVColor.bg.ignoresSafeArea()

                VStack(spacing: 0) {
                    if conversation.state == .idle, let arrival = notifications.lastScheduledArrival {
                        ScheduledArrivalBadge(arrival: arrival) {
                            conversation.resume(sessionId: arrival.sessionId)
                            notifications.clearArrival()
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 6)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if let turns = continuingTurnCount {
                        ContinuingPill(turns: turns) { activeSheet = .transcript }
                            .padding(.top, 6)
                    }

                    ScrollbackRail(
                        items: scrollbackTurns,
                        onTapTurn: { activeSheet = .transcript }
                    )

                    heroScroll
                }
                .padding(.top, 4)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: notifications.lastScheduledArrival)

                VStack(spacing: 0) {
                    Spacer()
                    BottomDock(
                        textInput: $textInput,
                        typingMode: $typingMode
                    )
                }
                .ignoresSafeArea(.keyboard, edges: .bottom)
            }
            .navigationTitle("HERMES VOICE")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .toolbarBackground(HVColor.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .sheet(item: $activeSheet) { sheet in
                // Single presenter. Inject env objects explicitly across the
                // sheet boundary (the documented Release-only crash class).
                switch sheet {
                case .settings:
                    SettingsView()
                        .environmentObject(settings)
                        .environmentObject(conversation)
                case .history:
                    HistoryView()
                        .environmentObject(settings)
                        .environmentObject(conversation)
                case .transcript:
                    TranscriptView()
                        .environmentObject(conversation)
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                // No background mic: leaving the foreground exits hands-free mode.
                if newPhase != .active && conversationMode.isActive {
                    conversationMode.stop()
                }
            }
            .alert("Conversation mode", isPresented: Binding(
                get: { conversationMode.errorMessage != nil },
                set: { if !$0 { conversationMode.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { conversationMode.errorMessage = nil }
            } message: {
                Text(conversationMode.errorMessage ?? "")
            }
        }
        .tint(HVColor.amber)
        .preferredColorScheme(.dark)
    }

    private var heroScroll: some View {
        ScrollView {
            // In hands-free mode, the listening pane replaces the hero while we
            // wait for the user; once a turn starts (.turn) the normal
            // thinking/speaking hero takes over.
            if conversationMode.phase == .listening {
                HeroListeningHandsFree(capture: conversationMode.capture)
                    .padding(.bottom, 180)
            } else {
                HeroPane(textInput: $textInput, isTyping: $typingMode, onSendText: sendText)
                    .padding(.bottom, 180)
            }
        }
        .scrollIndicators(.hidden)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Text("HERMES VOICE")
                .font(HVFont.title)
                .tracking(0.8)
                .foregroundStyle(HVColor.amber)
        }
        ToolbarItem(placement: .topBarLeading) {
            Button { activeSheet = .history } label: {
                Image(systemName: "clock")
                    .foregroundStyle(HVColor.bronze)
            }
            .accessibilityLabel("History")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { conversation.reset() } label: {
                Image(systemName: "square.and.pencil")
                    .foregroundStyle(canStartNewConversation ? HVColor.bronze : HVColor.creamFaint)
            }
            .disabled(!canStartNewConversation)
            .accessibilityLabel("New conversation")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { conversationMode.toggle() } label: {
                Image(systemName: conversationMode.isActive
                      ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
                    .foregroundStyle(conversationMode.isActive ? HVColor.amber : HVColor.bronze)
            }
            .accessibilityLabel(conversationMode.isActive ? "End conversation mode" : "Start conversation mode")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { activeSheet = .settings } label: {
                Image(systemName: "gearshape")
                    .foregroundStyle(HVColor.bronze)
            }
            .accessibilityLabel("Settings")
        }
    }

    /// "New conversation" is available only at rest (idle/error) and only when
    /// there's actually a thread to clear — resetting an empty one is a no-op.
    private var canStartNewConversation: Bool {
        let resting: Bool
        switch conversation.state {
        case .idle, .error: resting = true
        default: resting = false
        }
        return resting && (conversation.sessionId != nil || !conversation.messages.isEmpty)
    }

    /// Turns completed in the current in-memory thread, or nil when there's no
    /// active Hermes session yet (drives the "continuing · N" pill).
    private var continuingTurnCount: Int? {
        guard conversation.sessionId != nil else { return nil }
        let turns = conversation.messages.filter { $0.role == .user }.count
        return turns > 0 ? turns : nil
    }

    private func sendText() {
        let trimmed = textInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        textInput = ""
        typingMode = false
        Task { await conversation.sendText(trimmed) }
    }

    // Build collapsed-turn entries for the scrollback rail. A "turn" is a
    // user/assistant pair; we show the most recent two completed pairs,
    // excluding whatever is currently the hero pane's active turn.
    private var scrollbackTurns: [ScrollbackRail.Item] {
        let pairs = pairedTurns(in: conversation.messages)
        guard pairs.count > 1 else { return [] }
        // Drop the most-recent pair — that's the current hero.
        let collapsed = Array(pairs.dropLast().suffix(2))
        return collapsed.map { pair in
            ScrollbackRail.Item(
                id: pair.userMessage.id.uuidString,
                timestamp: Self.formatTime(pair.userMessage.timestamp),
                userText: pair.userMessage.text,
                replyText: pair.assistantMessage?.text ?? "",
                toolCount: pair.toolCount
            )
        }
    }

    private static func formatTime(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        return fmt.string(from: date)
    }
}

// MARK: - Scrollback Rail

struct ScrollbackRail: View {
    struct Item: Identifiable {
        let id: String
        let timestamp: String
        let userText: String
        let replyText: String
        let toolCount: Int
    }

    let items: [Item]
    let onTapTurn: () -> Void

    var body: some View {
        if items.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 6) {
                ForEach(items) { item in
                    ScrollbackPill(
                        timestamp: item.timestamp,
                        userText: item.userText,
                        replyText: item.replyText,
                        toolCount: item.toolCount,
                        onTap: onTapTurn
                    )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
    }
}

// MARK: - Scheduled-arrival badge

/// Surfaces the most-recent scheduled-fire notification while the app is at
/// rest. Tapping resumes that Hermes session so the user can continue it.
/// Shown only in `.idle` so it never covers an active turn.
private struct ScheduledArrivalBadge: View {
    let arrival: NotificationManager.ScheduledArrival
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(HVColor.gold)
                VStack(alignment: .leading, spacing: 1) {
                    Text("SCHEDULED UPDATE")
                        .font(HVFont.micro.weight(.semibold))
                        .tracking(1.0)
                        .foregroundStyle(HVColor.gold)
                    Text(arrival.body)
                        .font(HVFont.captionTiny)
                        .foregroundStyle(HVColor.cream)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(HVColor.gold)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10).fill(HVColor.goldGlow.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(HVColor.gold.opacity(0.35), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open scheduled update")
    }
}

// MARK: - Continuing-thread pill

/// Shown under the title while a Hermes session is active, so continuity is
/// visible (the now-playing hero only shows the latest turn). Tapping opens the
/// in-app transcript of the current thread.
private struct ContinuingPill: View {
    let turns: Int
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Circle().fill(HVColor.amber).frame(width: 5, height: 5)
                Text("CONTINUING · \(turns) TURN\(turns == 1 ? "" : "S")")
                    .font(HVFont.micro.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(HVColor.creamDim)
                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(HVColor.creamDim)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(HVColor.creamSurface))
            .overlay(Capsule().strokeBorder(HVColor.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open transcript — continuing \(turns) turns")
    }
}

// MARK: - Bottom dock

struct BottomDock: View {
    @EnvironmentObject var conversation: ConversationViewModel
    @EnvironmentObject var conversationMode: ConversationModeController
    @Binding var textInput: String
    @Binding var typingMode: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Soft fade from bg to make the dock pop without a hard line.
            LinearGradient(
                colors: [HVColor.bg.opacity(0), HVColor.bg],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 24)
            .allowsHitTesting(false)

            HStack(spacing: 18) {
                if conversationMode.isActive {
                    ConversationModeDock()
                } else if conversation.state == .speaking {
                    PlaybackTransport()
                } else {
                    DockSideButton(
                        systemName: typingMode ? "keyboard.fill" : "keyboard",
                        tint: typingMode ? HVColor.amber : HVColor.creamDim
                    ) {
                        typingMode.toggle()
                        if !typingMode { textInput = "" }
                    }
                    .accessibilityLabel("Toggle text input")

                    PushToTalkButton()
                        .opacity(typingMode ? 0.4 : 1.0)
                        .allowsHitTesting(!typingMode)

                    if isCancellable {
                        DockSideButton(
                            systemName: "xmark",
                            tint: HVColor.creamDim,
                            action: { conversation.cancelCurrentTurn() }
                        )
                        .accessibilityLabel("Cancel turn")
                    } else {
                        // Keep the mic centered. "New conversation" moved to the
                        // top bar, so the dock X is cancel-only and hidden at rest.
                        Color.clear.frame(width: 44, height: 44)
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 30)
            .background(HVColor.bg)
        }
    }

    /// The dock X is cancel-only now ("new conversation" moved to the top bar),
    /// shown only when there's an in-flight turn to cut. (`.speaking` uses the
    /// PlaybackTransport branch above, so this covers recording/sending/thinking.)
    private var isCancellable: Bool {
        switch conversation.state {
        case .recording, .thinking, .sending: return true
        default: return false
        }
    }
}

private struct DockSideButton: View {
    let systemName: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(HVColor.creamSurface)
                    .frame(width: 44, height: 44)
                Circle()
                    .strokeBorder(HVColor.hairline, lineWidth: 0.5)
                    .frame(width: 44, height: 44)
                Image(systemName: systemName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(tint)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct PlaybackTransport: View {
    @EnvironmentObject var conversation: ConversationViewModel

    var body: some View {
        HStack(spacing: 18) {
            // Back: skip to start of reply (not implemented — placeholder
            // for now; transport is mostly visual identity in speaks state).
            Button(action: {}) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(HVColor.creamDim)
                    .frame(width: 50, height: 50)
                    .background(Circle().fill(HVColor.creamSurface))
            }
            .buttonStyle(.plain)
            .disabled(true)

            // Stop: interrupts playback via the same path as the mic
            // button's barge-in.
            Button(action: { Task { await conversation.userPressedMic() } }) {
                ZStack {
                    Circle().fill(HVColor.gold).frame(width: 76, height: 76)
                    Circle().strokeBorder(HVColor.gold.opacity(0.18), lineWidth: 4)
                        .frame(width: 84, height: 84)
                    Image(systemName: "stop.fill")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(HVColor.bg)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop playback")

            Button(action: {}) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(HVColor.creamDim)
                    .frame(width: 50, height: 50)
                    .background(Circle().fill(HVColor.creamSurface))
            }
            .buttonStyle(.plain)
            .disabled(true)
        }
    }
}

// MARK: - Conversation-mode dock

/// Bottom dock while hands-free conversation mode is active: a phase-aware
/// center button (tap = barge-in: cut the reply and listen again) and an End
/// button. The mic gesture / push-to-talk dock is untouched and reappears when
/// conversation mode is off.
private struct ConversationModeDock: View {
    @EnvironmentObject var conversationMode: ConversationModeController

    var body: some View {
        HStack(spacing: 18) {
            Color.clear.frame(width: 44, height: 44)   // balance the End button

            Button(action: { conversationMode.bargeIn() }) {
                ZStack {
                    Circle().fill(centerFill).frame(width: 76, height: 76)
                    Circle().strokeBorder(centerFill.opacity(0.18), lineWidth: 4)
                        .frame(width: 84, height: 84)
                    Image(systemName: centerIcon)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(HVColor.bg)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(conversationMode.phase == .turn ? "Interrupt and listen" : "Listening")

            DockSideButton(systemName: "xmark", tint: HVColor.creamDim) {
                conversationMode.stop()
            }
            .accessibilityLabel("End conversation")
        }
    }

    private var centerIcon: String {
        conversationMode.phase == .turn ? "stop.fill" : "waveform"
    }
    private var centerFill: Color {
        conversationMode.phase == .turn ? HVColor.gold : HVColor.amber
    }
}

// MARK: - Turn grouping helper

struct TurnPair {
    let userMessage: Message
    let toolMessages: [Message]
    let assistantMessage: Message?

    var toolCount: Int { toolMessages.count }
}

/// Groups a flat message list into user/tool*/assistant turns. Used by the
/// scrollback rail to render past turns as compact pills.
func pairedTurns(in messages: [Message]) -> [TurnPair] {
    var pairs: [TurnPair] = []
    var i = 0
    while i < messages.count {
        guard messages[i].role == .user else {
            i += 1
            continue
        }
        let user = messages[i]
        var tools: [Message] = []
        var assistant: Message?
        var j = i + 1
        while j < messages.count, messages[j].role != .user {
            switch messages[j].role {
            case .toolCall: tools.append(messages[j])
            case .assistant: assistant = messages[j]
            case .user: break
            }
            j += 1
        }
        pairs.append(TurnPair(userMessage: user, toolMessages: tools, assistantMessage: assistant))
        i = j
    }
    return pairs
}
