import SwiftUI

struct MainView: View {
    @EnvironmentObject var conversation: ConversationViewModel
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var conversationMode: ConversationModeController
    @StateObject private var notifications = NotificationManager.shared
    @StateObject private var watchBridge = PhoneWatchBridge.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var activeSheet: ActiveSheet?
    @State private var textInput = ""
    @State private var typingMode = false

    // One sheet at a time. Multiple `.sheet(isPresented:)` modifiers stacked on
    // a single view shadow each other (History stopped opening once the
    // transcript sheet was added) — so route them all through one `.sheet(item:)`.
    private enum ActiveSheet: String, Identifiable {
        case settings, history, transcript, servers
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
            .navigationTitle(settings.activeAgentTitle)
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
                case .servers:
                    // BackendProfileManagerView is normally pushed via
                    // NavigationLink from inside SettingsView's own
                    // NavigationStack, so unlike the other cases here it
                    // doesn't wrap itself — do that (and match their
                    // tint/color-scheme) at this call site instead.
                    NavigationStack {
                        BackendProfileManagerView()
                            .environmentObject(settings)
                            .environmentObject(conversation)
                    }
                    .tint(HVColor.amber)
                    .preferredColorScheme(.dark)
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
        .overlay(alignment: .bottom) {
            if let approval = conversation.pendingApproval {
                ApprovalCard(approval: approval, listening: conversation.listeningForAnswer) {
                    conversation.answerApproval(allow: $0)
                }
                .padding(.bottom, 96)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let question = conversation.pendingQuestion {
                QuestionCard(question: question, listening: conversation.listeningForAnswer) {
                    conversation.answerQuestion($0)
                }
                .padding(.bottom, 96)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: conversation.pendingApproval)
        .animation(.spring(duration: 0.3), value: conversation.pendingQuestion)
        .tint(settings.agentAccent)
        .preferredColorScheme(.dark)
    }

    private var heroScroll: some View {
        ScrollViewReader { proxy in
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
                // Anchor the live feed follows as tool-call chips / the reply
                // append, so streaming tool calls don't march off-screen.
                Color.clear.frame(height: 1).id(Self.heroBottomAnchor)
            }
            .scrollIndicators(.hidden)
            // Key on the last message id (not count): it changes on every
            // append AND on the authoritative `.tools` removeAll+re-append swap,
            // which can keep the count unchanged and would otherwise not scroll.
            .onChange(of: conversation.messages.last?.id) {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(Self.heroBottomAnchor, anchor: .bottom)
                }
            }
        }
    }

    private static let heroBottomAnchor = "heroBottomAnchor"

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            BackendProfilePicker(
                canSwitch: canSwitchBackendProfile,
                select: selectBackendProfile,
                manage: { activeSheet = .servers }
            )
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
            Button { activeSheet = .settings } label: {
                Image(systemName: "gearshape")
                    .foregroundStyle(HVColor.bronze)
            }
            .accessibilityLabel("Settings")
        }
    }

    /// The header picker only opens when the active backend is actually
    /// switchable: never mid-turn/pending-approval (`canSwitchBackend`),
    /// never during hands-free (a switch mid-listen has nowhere sane to
    /// land), and never while relaying to the Watch (switching out from
    /// under a live relay would strand it).
    private var canSwitchBackendProfile: Bool {
        conversation.canSwitchBackend && !conversationMode.isActive && !watchBridge.isRelaying
    }

    /// Selecting the already-active profile is a no-op. Otherwise capture
    /// `previous` before any mutation (switching flips
    /// `settings.activeBackendProfile`), and only run the APNs handoff +
    /// notification cleanup once the switch actually lands.
    private func selectBackendProfile(_ profile: BackendProfile) {
        guard profile.id != settings.activeBackendProfile.id else { return }
        let previous = settings.activeBackendProfile
        guard conversation.switchBackend(to: profile.id) else { return }
        notifications.clearArrival()
        notifications.stopForegroundPlayback()
        notifications.handleBackendSwitch(previous: previous)
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
                leftControl
                centerControl
                rightControl
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 30)
            .background(HVColor.bg)
        }
    }

    // Left: keyboard (one-shot) — hidden in hands-free.
    @ViewBuilder private var leftControl: some View {
        if conversationMode.isActive {
            Color.clear.frame(width: 44, height: 44)
        } else {
            DockSideButton(
                systemName: typingMode ? "keyboard.fill" : "keyboard",
                tint: typingMode ? HVColor.amber : HVColor.creamDim
            ) {
                typingMode.toggle()
                if !typingMode { textInput = "" }
            }
            .accessibilityLabel("Toggle text input")
        }
    }

    // Center: the big button — push-to-talk mic (one-shot) or the hands-free
    // barge-in/listening button.
    @ViewBuilder private var centerControl: some View {
        if conversationMode.isActive {
            ConversationCenterButton()
        } else {
            PushToTalkButton()
                .opacity(typingMode ? 0.4 : 1.0)
                .allowsHitTesting(!typingMode)
        }
    }

    // Right (next to the mic): the mode toggle at rest; the cancel/End X when
    // there's something to stop.
    @ViewBuilder private var rightControl: some View {
        if conversationMode.isActive {
            DockSideButton(systemName: "xmark", tint: HVColor.creamDim) {
                conversationMode.stop()
            }
            .accessibilityLabel("End conversation")
        } else if isCancellable {
            DockSideButton(systemName: "xmark", tint: HVColor.creamDim) {
                conversation.cancelCurrentTurn()
            }
            .accessibilityLabel("Cancel turn")
        } else {
            ModeToggleButton()
        }
    }

    /// X is shown for any in-flight turn to cut — including `.speaking`, which
    /// now stops via the X (the old back/forward transport was placeholder-only).
    private var isCancellable: Bool {
        switch conversation.state {
        case .recording, .thinking, .sending, .speaking: return true
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

// MARK: - Mode toggle + hands-free center button

/// The mode toggle that sits next to the mic. Tap to switch between one-shot
/// (push-to-talk) and hands-free conversation mode. Shown at rest; hands-free
/// is exited via the dock's End (✕).
private struct ModeToggleButton: View {
    @EnvironmentObject var conversationMode: ConversationModeController

    var body: some View {
        Button { conversationMode.toggle() } label: {
            ZStack {
                Circle().fill(HVColor.creamSurface).frame(width: 44, height: 44)
                Circle().strokeBorder(HVColor.hairline, lineWidth: 0.5).frame(width: 44, height: 44)
                Image(systemName: "infinity")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(HVColor.creamDim)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Switch to hands-free mode")
    }
}

/// The big center button while hands-free is active: a real-time waveform-style
/// glyph while listening, a stop glyph during a reply (tap = barge-in: cut the
/// reply and listen again).
private struct ConversationCenterButton: View {
    @EnvironmentObject var conversationMode: ConversationModeController

    var body: some View {
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
