import SwiftUI
import WatchKit

/// Single-screen Watch UI: status chip + last reply + big amber mic button.
/// Press-and-hold to record, release to send. Haptic on completion.
struct WatchMainView: View {
    @EnvironmentObject var session: WatchSession
    @State private var recorder = WatchRecorder()

    var body: some View {
        ZStack {
            HVColor.bg.ignoresSafeArea()

            VStack(spacing: 6) {
                header

                statusChip
                    .padding(.bottom, 2)

                if !session.lastResponseText.isEmpty {
                    ScrollView {
                        HStack(alignment: .top, spacing: 4) {
                            Text("←").foregroundStyle(HVColor.gold)
                            Text(session.lastResponseText)
                                .font(HVFont.bodyDim)
                                .foregroundStyle(HVColor.cream)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxHeight: 76)
                } else {
                    Spacer(minLength: 0)
                }

                micButton
                    .padding(.bottom, 6)
            }
            .padding(.horizontal, 4)
        }
    }

    private var header: some View {
        HStack {
            Text("HERMES")
                .font(HVFont.chip)
                .tracking(0.6)
                .foregroundStyle(HVColor.amber)
            Spacer()
            if !session.phoneReachable {
                Image(systemName: "iphone.slash")
                    .font(.system(size: 10))
                    .foregroundStyle(HVColor.bronze)
            }
        }
    }

    private var statusChip: some View {
        HStack(spacing: 5) {
            if descriptor.showDot {
                Circle()
                    .fill(descriptor.color)
                    .frame(width: 5, height: 5)
            }
            Text(descriptor.label)
                .font(HVFont.chip)
                .tracking(0.6)
                .foregroundStyle(descriptor.color)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(descriptor.bg))
    }

    private struct Descriptor {
        let label: String
        let color: Color
        let bg: Color
        let showDot: Bool
    }

    private var descriptor: Descriptor {
        switch session.state {
        case .idle:
            return .init(label: "IDLE", color: HVColor.creamDim,
                         bg: HVColor.creamSurface, showDot: false)
        case .recording:
            return .init(label: "LISTENS", color: HVColor.amber,
                         bg: HVColor.amberGlow, showDot: true)
        case .sending:
            return .init(label: "SENDING", color: HVColor.amber,
                         bg: HVColor.amberGlow, showDot: true)
        case .thinking:
            return .init(label: "PONDERS", color: HVColor.bronze,
                         bg: HVColor.bronze.opacity(0.16), showDot: true)
        case .error:
            return .init(label: "OFFLINE", color: HVColor.dangerSoft,
                         bg: HVColor.danger.opacity(0.14), showDot: true)
        }
    }

    private var micButton: some View {
        ZStack {
            Circle()
                .fill(buttonColor)
                .frame(width: 86, height: 86)
            if isRecording {
                Circle()
                    .strokeBorder(HVColor.amber.opacity(0.35), lineWidth: 3)
                    .frame(width: 100, height: 100)
            }
            Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(HVColor.bg)
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in beginIfIdle() }
                .onEnded { _ in endIfRecording() }
        )
    }

    private var isRecording: Bool {
        if case .recording = session.state { return true } else { return false }
    }

    private var buttonColor: Color {
        if isRecording { return HVColor.amber }
        switch session.state {
        case .sending, .thinking: return HVColor.bronze
        case .error: return HVColor.danger
        default: return HVColor.amber
        }
    }

    private func beginIfIdle() {
        switch session.state {
        case .idle, .error:
            Task { await startRecording() }
        default:
            break
        }
    }

    private func endIfRecording() {
        guard isRecording else { return }
        Task { await stopAndSend() }
    }

    private func startRecording() async {
        do {
            try await recorder.start()
            session.setState(.recording)
            WKInterfaceDevice.current().play(.start)
        } catch {
            session.setState(.error(error.localizedDescription))
        }
    }

    private func stopAndSend() async {
        guard let url = recorder.stop() else {
            session.setState(.error("No audio"))
            return
        }
        WKInterfaceDevice.current().play(.stop)
        session.sendAudio(fileURL: url, sessionId: session.sessionId)
    }
}
