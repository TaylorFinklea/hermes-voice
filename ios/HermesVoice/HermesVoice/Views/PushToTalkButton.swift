import SwiftUI

/// Dual-mode push-to-talk: hold to talk (release sends), OR brief tap to
/// latch into recording and tap again to stop. Visually owns the brand-
/// styled MicCircle; the gesture/state plumbing lives here, the appearance
/// in MicCircle (Atoms.swift).
struct PushToTalkButton: View {
    @EnvironmentObject var conversation: ConversationViewModel

    @GestureState private var isPressing = false
    @State private var latched = false
    @State private var pressStart: Date?

    private let tapThreshold: TimeInterval = 0.35
    private let buttonSize: CGFloat = 88

    var body: some View {
        ZStack {
            // Pulsing ring while recording — sized so it sits just outside
            // the mic circle's halo without overlapping the side buttons.
            if conversation.state == .recording {
                RecordingPulseRing(diameter: buttonSize)
            }
            MicCircle(state: micState, size: buttonSize)
                .scaleEffect(isPressing || conversation.state == .recording ? 1.04 : 1.0)
                .animation(.spring(response: 0.22, dampingFraction: 0.75),
                           value: conversation.state)
                .animation(.spring(response: 0.22, dampingFraction: 0.75),
                           value: isPressing)
        }
        .frame(width: buttonSize + 24, height: buttonSize + 24)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($isPressing) { _, state, _ in state = true }
                .onChanged { _ in
                    if pressStart == nil { pressStart = .now }
                    Task { await beginIfNotRecording() }
                }
                .onEnded { _ in
                    let held = Date.now.timeIntervalSince(pressStart ?? .now)
                    pressStart = nil
                    if latched {
                        latched = false
                        Task { await conversation.stopRecordingAndSend() }
                        return
                    }
                    if held < tapThreshold {
                        latched = true
                    } else {
                        Task { await conversation.stopRecordingAndSend() }
                    }
                }
        )
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Hold to talk, or tap to start and tap again to stop.")
    }

    /// Map VM state to the visual mic-circle state. `.error` falls back to
    /// `.idle` so the button still looks tappable when recovering.
    private var micState: MicState {
        conversation.state.micState ?? .idle
    }

    private var accessibilityLabel: String {
        switch conversation.state {
        case .recording: return "Stop recording"
        case .speaking: return "Interrupt and talk"
        case .thinking, .sending: return "Cancel and talk"
        default: return "Push to talk"
        }
    }

    private func beginIfNotRecording() async {
        if case .recording = conversation.state { return }
        await conversation.userPressedMic()
    }
}

/// Expanding amber ring that emanates from the mic circle while recording.
/// Mirrors the @keyframes e-ring animation in the mockup.
private struct RecordingPulseRing: View {
    let diameter: CGFloat
    @State private var scale: CGFloat = 0.85
    @State private var opacity: Double = 0.8

    var body: some View {
        Circle()
            .strokeBorder(HVColor.amber.opacity(0.55), lineWidth: 1.5)
            .frame(width: diameter, height: diameter)
            .scaleEffect(scale)
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeOut(duration: 1.5).repeatForever(autoreverses: false)) {
                    scale = 1.5
                    opacity = 0
                }
            }
    }
}
