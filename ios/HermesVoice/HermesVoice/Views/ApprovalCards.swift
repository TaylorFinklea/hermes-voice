import SwiftUI

/// Phase B: shown when a write turn pauses for approval ("Claude wants to edit
/// X — Approve/Deny"). The prompt is also spoken aloud (see speakPrompt). Tap
/// to answer; the turn resumes on the answer POST.
struct ApprovalCard: View {
    let approval: ConversationViewModel.PendingApproval
    var listening: Bool = false
    let onAnswer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(HVColor.amber)
                Text("APPROVAL")
                    .font(HVFont.chip).tracking(0.7)
                    .foregroundStyle(HVColor.amber)
                Spacer()
            }
            Text(approval.title)
                .font(HVFont.body)
                .foregroundStyle(HVColor.cream)
                .multilineTextAlignment(.leading)
            if !approval.preview.isEmpty {
                Text(approval.preview)
                    .font(HVFont.captionTiny)
                    .foregroundStyle(HVColor.creamDim)
                    .lineLimit(3)
            }
            if listening { listeningRow("Listening — say “yes” or “no”") }
            HStack(spacing: 10) {
                cardButton("Deny", tint: HVColor.dangerSoft) { onAnswer(false) }
                cardButton("Approve", tint: HVColor.amber, filled: true) { onAnswer(true) }
            }
        }
        .padding(16)
        .background(cardBackground)
        .padding(.horizontal, 16)
    }
}

/// Phase B: the agent asked a single- or multi-select question (the AskUser
/// tool). Single-select answers on tap; multi-select gathers then Send.
struct QuestionCard: View {
    let question: ConversationViewModel.PendingQuestion
    var listening: Bool = false
    let onAnswer: ([String]) -> Void

    @State private var selected: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(HVColor.amber)
                Text(question.multi ? "SELECT ANY" : "SELECT ONE")
                    .font(HVFont.chip).tracking(0.7)
                    .foregroundStyle(HVColor.amber)
                Spacer()
            }
            Text(question.prompt)
                .font(HVFont.body)
                .foregroundStyle(HVColor.cream)
                .multilineTextAlignment(.leading)
            if listening {
                listeningRow(question.multi
                    ? "Listening — name the options"
                    : "Listening — say an option")
            }
            ForEach(question.options, id: \.self) { opt in
                Button { tap(opt) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: glyph(for: opt))
                            .foregroundStyle(selected.contains(opt) ? HVColor.amber : HVColor.creamDim)
                        Text(opt)
                            .font(HVFont.body)
                            .foregroundStyle(HVColor.cream)
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
            if question.multi {
                cardButton("Send", tint: HVColor.amber, filled: true) {
                    onAnswer(Array(selected))
                }
                .disabled(selected.isEmpty)
                .opacity(selected.isEmpty ? 0.5 : 1)
            }
        }
        .padding(16)
        .background(cardBackground)
        .padding(.horizontal, 16)
    }

    private func glyph(for opt: String) -> String {
        if question.multi {
            return selected.contains(opt) ? "checkmark.square.fill" : "square"
        }
        return selected.contains(opt) ? "largecircle.fill.circle" : "circle"
    }

    private func tap(_ opt: String) {
        if question.multi {
            if selected.contains(opt) { selected.remove(opt) } else { selected.insert(opt) }
        } else {
            selected = [opt]
            onAnswer([opt])
        }
    }
}

// MARK: - shared bits

/// A subtle "listening for your spoken answer" affordance shown on a card while
/// the voice-answer listener is armed. Purely informational — the buttons still
/// work, and the mic button keeps its barge-in/cancel meaning.
@ViewBuilder
private func listeningRow(_ label: String) -> some View {
    HStack(spacing: 7) {
        Image(systemName: "waveform")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(HVColor.amber)
            .symbolEffect(.variableColor.iterative, options: .repeating)
        Text(label)
            .font(HVFont.captionTiny)
            .foregroundStyle(HVColor.creamDim)
        Spacer()
    }
    .padding(.vertical, 2)
}

private var cardBackground: some View {
    RoundedRectangle(cornerRadius: 14)
        .fill(HVColor.bg2)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(HVColor.amber.opacity(0.4), lineWidth: 1)
        )
}

@ViewBuilder
private func cardButton(
    _ title: String, tint: Color, filled: Bool = false, action: @escaping () -> Void
) -> some View {
    Button(action: action) {
        Text(title)
            .font(HVFont.body.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .foregroundStyle(filled ? HVColor.bg : tint)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(filled ? tint : tint.opacity(0.14))
            )
    }
    .buttonStyle(.plain)
}
