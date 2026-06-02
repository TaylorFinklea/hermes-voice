import SwiftUI

// State enum decoupled from ConversationViewModel so atoms can be previewed
// in isolation. Map via ConversationViewModel.State.micState.
enum MicState: String, CaseIterable {
    case idle, recording, sending, thinking, speaking
}

extension ConversationViewModel.State {
    var micState: MicState? {
        switch self {
        case .idle: return .idle
        case .recording: return .recording
        case .sending: return .sending
        case .thinking: return .thinking
        case .speaking: return .speaking
        case .error: return nil
        }
    }
}

// MARK: - StatusChip

struct StatusChip: View {
    let state: MicState
    var compact: Bool = false
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(spacing: 6) {
            if descriptor.showDot {
                Circle()
                    .fill(descriptor.color)
                    .frame(width: 6, height: 6)
                    .shadow(color: state == .recording ? descriptor.color.opacity(0.7) : .clear, radius: 3)
                    .scaleEffect(pulse ? 1.0 : 0.7)
                    .animation(state == .recording ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default, value: pulse)
                    .onAppear { pulse = true }
            }
            Text("\(settings.activeAgentLabel) \(descriptor.label)")
                .font(compact ? HVFont.chipTiny : HVFont.chip)
                .tracking(0.7)
                .foregroundStyle(descriptor.color)
        }
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.vertical, compact ? 3 : 5)
        .background(
            Capsule().fill(descriptor.bg)
        )
    }

    @State private var pulse = false

    private struct Descriptor {
        let label: String
        let color: Color
        let bg: Color
        let showDot: Bool
    }

    private var descriptor: Descriptor {
        switch state {
        case .idle:
            return .init(label: "IDLE", color: HVColor.creamDim,
                         bg: HVColor.creamSurface, showDot: false)
        case .recording:
            return .init(label: "LISTENS", color: HVColor.amber,
                         bg: HVColor.amberGlow.opacity(0.7), showDot: true)
        case .sending:
            return .init(label: "SENDING", color: HVColor.amber,
                         bg: HVColor.amberGlow.opacity(0.7), showDot: true)
        case .thinking:
            return .init(label: "PONDERS", color: HVColor.bronze,
                         bg: HVColor.bronzeGlow, showDot: true)
        case .speaking:
            return .init(label: "SPEAKS", color: HVColor.gold,
                         bg: HVColor.goldGlow.opacity(0.7), showDot: true)
        }
    }
}

// MARK: - ToolChip

// Bronze tool-call audit chip: ⚙ name · cmd preview · ✓ · 0.4s
struct ToolChip: View {
    let name: String
    let preview: String
    var ok: Bool = true
    var duration: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text("⚙")
                .font(HVFont.captionTiny)
                .foregroundStyle(HVColor.bronze)
            Text(name)
                .font(HVFont.captionTiny.weight(.semibold))
                .foregroundStyle(HVColor.bronze)
            if !preview.isEmpty {
                Text("·").foregroundStyle(HVColor.creamFaint)
                Text(preview)
                    .font(HVFont.captionTiny)
                    .foregroundStyle(HVColor.creamDim)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            Text(ok ? "✓" : "✗")
                .font(HVFont.micro)
                .foregroundStyle(ok ? HVColor.amber : HVColor.danger)
            if let duration {
                Text(duration)
                    .font(HVFont.micro)
                    .foregroundStyle(HVColor.creamDim)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(HVColor.bronzeGlow.opacity(0.5))
        )
    }
}

// MARK: - MicCircle

struct MicCircle: View {
    let state: MicState
    var size: CGFloat = 84

    var body: some View {
        ZStack {
            Circle()
                .fill(fillColor)
                .overlay(
                    Circle().strokeBorder(strokeColor, lineWidth: 2)
                )
                .shadow(color: haloColor, radius: state == .recording ? 14 : 0)

            content
                .frame(width: size * 0.45, height: size * 0.45)
        }
        .frame(width: size, height: size)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: state)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle, .recording:
            Image(systemName: "mic.fill")
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(HVColor.bg)
        case .sending:
            SpinnerArc(color: HVColor.amber)
        case .thinking:
            BounceDots(color: HVColor.bronze)
        case .speaking:
            SpeakBars(color: HVColor.gold)
        }
    }

    private var fillColor: Color {
        switch state {
        case .idle, .recording: return HVColor.amber
        case .sending, .thinking, .speaking: return .clear
        }
    }

    private var strokeColor: Color {
        switch state {
        case .idle, .recording: return HVColor.amber
        case .sending: return HVColor.amber
        case .thinking: return HVColor.bronze
        case .speaking: return HVColor.gold
        }
    }

    private var haloColor: Color {
        state == .recording ? HVColor.amber.opacity(0.55) : .clear
    }
}

// Three bouncing dots for the "thinking" mic.
private struct BounceDots: View {
    let color: Color
    @State private var phase: Double = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                    .opacity(opacity(for: i))
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }

    private func opacity(for i: Int) -> Double {
        let offset = Double(i) * 0.25
        let v = (phase + offset).truncatingRemainder(dividingBy: 1)
        return 0.3 + 0.7 * sin(v * .pi)
    }
}

// Equalizer-style bars for the "speaking" mic.
private struct SpeakBars: View {
    let color: Color
    @State private var t: CGFloat = 0

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<6, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: 3, height: barHeight(for: i))
            }
        }
        .frame(height: 26)
        .onAppear {
            withAnimation(.linear(duration: 0.6).repeatForever(autoreverses: false)) {
                t = .pi * 2
            }
        }
    }

    private func barHeight(for i: Int) -> CGFloat {
        let baseHeights: [CGFloat] = [8, 16, 22, 14, 18, 10]
        let mod = sin(t + CGFloat(i) * 0.7) * 0.4 + 0.6
        return baseHeights[i] * mod + 4
    }
}

// Rotating spinner arc for the "sending" mic.
private struct SpinnerArc: View {
    let color: Color
    @State private var rotation: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0.0, to: 0.4)
            .stroke(color, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

// MARK: - ScrollbackPill

struct ScrollbackPill: View {
    let timestamp: String
    let userText: String
    let replyText: String
    let toolCount: Int
    var onTap: () -> Void = {}

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Text(timestamp)
                    .font(HVFont.micro)
                    .tracking(0.5)
                    .foregroundStyle(HVColor.creamDim)
                    .frame(width: 50, alignment: .leading)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        Text("›").foregroundStyle(HVColor.amber)
                        Text(userText)
                            .foregroundStyle(HVColor.creamDim)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(HVFont.captionTiny)
                    HStack(spacing: 4) {
                        Text("←").foregroundStyle(HVColor.gold)
                        Text(replyText)
                            .foregroundStyle(HVColor.cream)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(HVFont.captionTiny)
                }
                Spacer(minLength: 0)
                if toolCount > 0 {
                    Text("⚙ \(toolCount)")
                        .font(HVFont.micro)
                        .foregroundStyle(HVColor.bronze)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10).fill(HVColor.creamSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10).strokeBorder(HVColor.hairline, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Pipeline step (for sending state)

struct PipelineStep: View {
    enum Status { case done, active, pending }
    let label: String
    let status: Status

    var body: some View {
        HStack(spacing: 10) {
            indicator
            Text(label)
                .font(HVFont.caption)
                .foregroundStyle(textColor)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(background)
        )
    }

    @ViewBuilder
    private var indicator: some View {
        ZStack {
            Circle()
                .fill(status == .done ? HVColor.amber : .clear)
                .frame(width: 16, height: 16)
            Circle()
                .strokeBorder(borderColor, lineWidth: 1.5)
                .frame(width: 16, height: 16)
            switch status {
            case .done:
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(HVColor.bg)
            case .active:
                SpinnerArc(color: HVColor.amber)
                    .frame(width: 11, height: 11)
            case .pending:
                EmptyView()
            }
        }
    }

    private var background: Color {
        status == .active ? HVColor.amberGlow.opacity(0.4) : HVColor.creamSurface.opacity(0.6)
    }
    private var textColor: Color {
        status == .pending ? HVColor.creamFaint : HVColor.creamDim
    }
    private var borderColor: Color {
        switch status {
        case .done, .active: return HVColor.amber
        case .pending: return HVColor.creamFaint
        }
    }
}

