import SwiftUI

// The center stage of the now-playing layout. The current turn dominates;
// past turns live in the scrollback rail above. Each state subview owns its
// own copy + chrome so MainView stays a thin switch.
struct HeroPane: View {
    @EnvironmentObject var conversation: ConversationViewModel
    let textInput: Binding<String>
    let isTyping: Binding<Bool>
    let onSendText: () -> Void

    var body: some View {
        Group {
            if case .error(let msg) = conversation.state {
                HeroError(message: msg)
            } else if isTyping.wrappedValue {
                HeroTextInput(text: textInput, onSend: onSendText)
            } else if conversation.messages.isEmpty && conversation.state == .idle {
                HeroFirstLaunch()
            } else {
                switch conversation.state {
                case .idle:           HeroJustArrived()
                case .recording:      HeroListens()
                case .sending:        HeroSending()
                case .thinking:       HeroThinks()
                case .speaking:       HeroSpeaks()
                case .error:          EmptyView()
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - First launch / fresh conversation

private struct HeroFirstLaunch: View {
    private let suggestions: [(category: String, text: String, glyph: String)] = [
        ("memory",  "“Save this thought…”",            "mic.fill"),
        ("control", "“Turn off the kitchen lights.”",  "wrench.and.screwdriver.fill"),
        ("admin",   "“What's on my calendar today?”",  "clock.fill"),
    ]

    var body: some View {
        VStack(alignment: .center, spacing: 18) {
            ZStack {
                Circle()
                    .fill(HVColor.amber.opacity(0.10))
                    .frame(width: 96, height: 96)
                Image(systemName: "mic.fill")
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(HVColor.amber)
            }
            .padding(.top, 12)

            VStack(spacing: 8) {
                Text("Hold to begin.")
                    .font(HVFont.largeTitle)
                    .foregroundStyle(HVColor.cream)
                    .multilineTextAlignment(.center)
                Text("Hermes runs on your Mac and listens through this app. Press and hold the mic, say what you need, release.")
                    .font(HVFont.bodyDim)
                    .foregroundStyle(HVColor.creamDim)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.horizontal, 4)
            }

            VStack(spacing: 0) {
                HStack {
                    Text("TRY")
                        .font(HVFont.captionTiny.weight(.semibold))
                        .tracking(1.2)
                        .foregroundStyle(HVColor.bronze)
                    Spacer()
                }
                .padding(.bottom, 8)

                VStack(spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.offset) { idx, item in
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(HVColor.amber.opacity(0.10))
                                    .frame(width: 28, height: 28)
                                Image(systemName: item.glyph)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(HVColor.amber)
                            }
                            Text(item.text)
                                .font(HVFont.bodyDim)
                                .foregroundStyle(HVColor.cream)
                            Spacer()
                            Text(item.category.uppercased())
                                .font(HVFont.micro)
                                .tracking(1.0)
                                .foregroundStyle(HVColor.bronze)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        if idx < suggestions.count - 1 {
                            Rectangle().fill(HVColor.hairline).frame(height: 0.5)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 12).fill(HVColor.creamSurface)
                )
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Listens (recording)

private struct HeroListens: View {
    @EnvironmentObject var conversation: ConversationViewModel
    @State private var elapsed: TimeInterval = 0
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                StatusChip(state: .recording)
                Spacer()
                Text(formatElapsed(elapsed))
                    .font(HVFont.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(HVColor.amber)
            }

            Waveform(active: true)
                .frame(height: 56)

            Text("listening…")
                .font(HVFont.heroSpeak)
                .foregroundStyle(HVColor.amber)

            Text("Release to send.")
                .font(HVFont.captionTiny)
                .tracking(0.6)
                .foregroundStyle(HVColor.creamDim)
        }
        .onReceive(timer) { _ in
            elapsed = conversation.elapsedRecordingTime
        }
    }

    private func formatElapsed(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: - Sending (post-release, pre-response)

private struct HeroSending: View {
    @EnvironmentObject var conversation: ConversationViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                StatusChip(state: .sending)
                Spacer()
                if let dur = conversation.lastClipDuration {
                    Text(String(format: "%.1fs clip", dur))
                        .font(HVFont.caption)
                        .monospacedDigit()
                        .foregroundStyle(HVColor.creamDim)
                }
            }

            SectionLabel("Pipeline")

            VStack(spacing: 6) {
                PipelineStep(
                    label: conversation.lastClipDuration.map { String(format: "captured %.1fs audio", $0) } ?? "captured audio",
                    status: .done
                )
                if conversation.sendingPhase == .transcribing {
                    // On-device path: nothing uploads — parakeet runs locally,
                    // then we jump straight to the thinking pane.
                    PipelineStep(label: "transcribing on device", status: .active)
                } else {
                    PipelineStep(
                        label: "uploading to backend",
                        status: conversation.sendingPhase == .uploading ? .active : .done
                    )
                    PipelineStep(
                        label: "transcribing + dispatching to hermes",
                        status: conversation.sendingPhase == .processing ? .active : .pending
                    )
                }
            }
        }
    }
}

// MARK: - Thinks (waiting on Hermes)

private struct HeroThinks: View {
    @EnvironmentObject var conversation: ConversationViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                StatusChip(state: .thinking)
                Spacer()
            }

            if let userText = conversation.lastUserText {
                Text("›  \(userText)")
                    .font(HVFont.heroUser)
                    .foregroundStyle(HVColor.cream)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !conversation.toolCalls.isEmpty {
                SectionLabel("Tool calls (\(conversation.toolCalls.count))")
                VStack(spacing: 6) {
                    ForEach(Array(conversation.toolCalls.enumerated()), id: \.offset) { _, tc in
                        ToolChip(name: tc.toolCall?.name ?? "tool",
                                 preview: tc.toolCall?.preview ?? "",
                                 ok: tc.toolCall?.ok ?? true)
                    }
                }
            }

            HStack(spacing: 10) {
                BounceLabel(text: "Composing reply…", color: HVColor.bronze)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10).fill(HVColor.bronzeGlow.opacity(0.5))
            )
        }
    }
}

private struct BounceLabel: View {
    let text: String
    let color: Color
    @State private var t: Double = 0

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(color)
                        .frame(width: 4, height: 4)
                        .opacity(opacity(for: i))
                }
            }
            Text(text)
                .font(HVFont.bodyDim)
                .foregroundStyle(color)
            Spacer(minLength: 0)
        }
        .onAppear {
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { t = 1 }
        }
    }
    private func opacity(for i: Int) -> Double {
        let offset = Double(i) * 0.2
        let v = (t + offset).truncatingRemainder(dividingBy: 1)
        return 0.3 + 0.7 * sin(v * .pi)
    }
}

// MARK: - Speaks

private struct HeroSpeaks: View {
    @EnvironmentObject var conversation: ConversationViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                StatusChip(state: .speaking)
                Spacer()
            }

            if let userText = conversation.lastUserText {
                Text("›  \(userText)")
                    .font(HVFont.bodyDim)
                    .foregroundStyle(HVColor.creamDim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !conversation.toolCalls.isEmpty {
                VStack(spacing: 4) {
                    ForEach(Array(conversation.toolCalls.enumerated()), id: \.offset) { _, tc in
                        ToolChip(name: tc.toolCall?.name ?? "tool",
                                 preview: tc.toolCall?.preview ?? "",
                                 ok: tc.toolCall?.ok ?? true)
                    }
                }
            }

            if let assistantText = conversation.lastAssistantText {
                if let card = ActionCard.detect(in: conversation.messages) {
                    ActionCardView(card: card)
                    Text("←  \(assistantText)")
                        .font(HVFont.heroReply)
                        .foregroundStyle(HVColor.cream)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("←  \(assistantText)")
                        .font(HVFont.heroSpeak.weight(.medium))
                        .foregroundStyle(HVColor.cream)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Just arrived (post-reply, before next turn)

private struct HeroJustArrived: View {
    @EnvironmentObject var conversation: ConversationViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                StatusChip(state: .idle)
                Spacer()
                Text("just now")
                    .font(HVFont.captionTiny)
                    .foregroundStyle(HVColor.creamDim)
            }

            HStack(alignment: .top, spacing: 0) {
                Rectangle()
                    .fill(HVColor.gold.opacity(0.45))
                    .frame(width: 2)
                VStack(alignment: .leading, spacing: 10) {
                    if let userText = conversation.lastUserText {
                        Text("›  \(userText)")
                            .font(HVFont.bodyDim)
                            .foregroundStyle(HVColor.creamDim)
                    }
                    if !conversation.toolCalls.isEmpty {
                        VStack(spacing: 4) {
                            ForEach(Array(conversation.toolCalls.enumerated()), id: \.offset) { _, tc in
                                ToolChip(name: tc.toolCall?.name ?? "tool",
                                         preview: tc.toolCall?.preview ?? "",
                                         ok: tc.toolCall?.ok ?? true)
                            }
                        }
                    }
                    if let assistantText = conversation.lastAssistantText {
                        if let card = ActionCard.detect(in: conversation.messages) {
                            ActionCardView(card: card)
                        }
                        Text("←  \(assistantText)")
                            .font(HVFont.heroReply)
                            .foregroundStyle(HVColor.cream)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 12)
            }
            .opacity(0.95)

            HStack(spacing: 8) {
                Text("↓").foregroundStyle(HVColor.amber)
                Text("Hold the mic to follow up — context is kept.")
                    .font(HVFont.caption)
                    .foregroundStyle(HVColor.creamDim)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10).fill(HVColor.creamSurface)
            )
        }
    }
}

// MARK: - Error

private struct HeroError: View {
    let message: String
    @EnvironmentObject var conversation: ConversationViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 6) {
                    Circle().fill(HVColor.dangerSoft).frame(width: 6, height: 6)
                    Text("HERMES OFFLINE")
                        .font(HVFont.chip)
                        .tracking(0.7)
                        .foregroundStyle(HVColor.dangerSoft)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(HVColor.danger.opacity(0.14)))
                Spacer()
            }

            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(HVColor.danger).frame(width: 22, height: 22)
                    Text("!").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Backend unreachable.")
                        .font(HVFont.caption.weight(.semibold))
                        .foregroundStyle(HVColor.cream)
                    Text(message)
                        .font(HVFont.captionTiny)
                        .foregroundStyle(HVColor.creamDim)
                        .lineLimit(3)
                }
                Spacer(minLength: 0)
                Button("retry") {
                    conversation.clearError()
                }
                .font(HVFont.captionTiny.weight(.semibold))
                .foregroundStyle(HVColor.dangerSoft)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8).fill(HVColor.danger.opacity(0.20))
                )
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10).fill(HVColor.danger.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10).strokeBorder(HVColor.danger.opacity(0.35), lineWidth: 0.5)
            )
        }
    }
}

// MARK: - Text input mode

private struct HeroTextInput: View {
    @Binding var text: String
    let onSend: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 6) {
                    Text("HERMES TYPING")
                        .font(HVFont.chip)
                        .tracking(0.7)
                        .foregroundStyle(HVColor.creamDim)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(HVColor.creamSurface))
                Spacer()
                Text("text fallback")
                    .font(HVFont.captionTiny)
                    .foregroundStyle(HVColor.creamDim)
            }

            Text("When you can't talk — same Hermes, typed.")
                .font(HVFont.captionTiny)
                .tracking(0.4)
                .foregroundStyle(HVColor.creamDim)

            HStack(alignment: .bottom, spacing: 10) {
                Text("›")
                    .font(HVFont.body)
                    .foregroundStyle(HVColor.amber)
                    .padding(.bottom, 4)
                TextField("", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(HVFont.body)
                    .foregroundStyle(HVColor.cream)
                    .focused($focused)
                    .onSubmit(onSend)
                    .lineLimit(1...5)
                Button(action: onSend) {
                    ZStack {
                        Circle().fill(HVColor.amber).frame(width: 28, height: 28)
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(HVColor.bg)
                    }
                }
                .buttonStyle(.plain)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 18).fill(HVColor.creamSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18).strokeBorder(HVColor.amber.opacity(0.3), lineWidth: 0.5)
            )
            .onAppear { focused = true }
        }
    }
}

// MARK: - Helpers

struct SectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(HVFont.captionTiny.weight(.semibold))
            .tracking(1.2)
            .foregroundStyle(HVColor.bronze)
    }
}

// Static-shape waveform for the listens state. We can't easily tap into
// AVAudioRecorder's level meter without restructuring the recorder, so this
// fakes a plausible spoken-word envelope and animates a phase offset. The
// effect is visually equivalent for the user.
struct Waveform: View {
    let active: Bool
    @State private var phase: Double = 0
    private let barCount = 56

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<barCount, id: \.self) { i in
                    Capsule()
                        .fill(HVColor.amber)
                        .frame(width: 3, height: height(at: i, t: t))
                }
            }
        }
    }

    private func height(at i: Int, t: Double) -> CGFloat {
        let base = sin(Double(i) / 2.2 + t * 6) * sin(Double(i) / 7) * 18
        let envelope = sin(Double(i) / 9 + t * 0.5) * 6
        return max(3, CGFloat(abs(base + envelope) + 4))
    }
}
