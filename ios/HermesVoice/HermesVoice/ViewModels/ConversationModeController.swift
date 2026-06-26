import Foundation
import AVFoundation
import SwiftUI

/// Drives hands-free conversation mode by *composing* the existing turn
/// primitives — it does NOT extend `ConversationViewModel.State`. The loop:
///   listen (VAD endpoint) → transcribe on-device → `vm.sendText` (runs the
///   whole turn incl. on-device Kokoro speak) → re-arm listening.
///
/// `vm.sendText` awaits the turn to completion, so "reply finished → listen
/// again" is simply the next line after the await — no state-observation race.
/// Half-duplex: the capture engine releases the mic during the reply and
/// re-acquires on re-arm, so the mic is never hot while Kokoro speaks.
@MainActor
final class ConversationModeController: ObservableObject {
    /// `.listening` → show the hands-free listening pane; `.turn` → defer to the
    /// VM's thinking/speaking hero; `.off` → not in conversation mode.
    enum Phase: Equatable { case off, listening, turn }
    @Published private(set) var phase: Phase = .off

    /// Surfaced to the user via an alert (mic denied, model not ready, capture
    /// failure). Cleared when dismissed.
    @Published var errorMessage: String?

    var isActive: Bool { phase != .off }

    let capture = ConversationCaptureEngine()

    private let vm: ConversationViewModel
    private var loopTask: Task<Void, Never>?

    /// Auto-exit guards against a hot mic left listening to an empty room.
    private static let maxEmptyCycles = 3
    private static let maxSessionSeconds: TimeInterval = 15 * 60

    init(vm: ConversationViewModel) {
        self.vm = vm
    }

    // MARK: - Entry / exit

    func toggle() {
        if isActive { stop() } else { start() }
    }

    func start() {
        guard phase == .off, loopTask == nil else { return }
        guard LocalVad.shared.isReady else {
            errorMessage = "Download the hands-free listening model in Settings first."
            return
        }
        guard LocalSpeaker.shared.isReady else {
            errorMessage = "Pick an on-device voice in Settings first — hands-free needs it to reply."
            return
        }
        loopTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.ensureMicPermission() else {
                self.errorMessage = "Microphone access not granted."
                self.loopTask = nil
                return
            }
            await self.runLoop()
        }
    }

    /// Exit conversation mode and release everything. Fixed teardown order so no
    /// component deactivates the audio session out from under another.
    func stop() {
        loopTask?.cancel()
        loopTask = nil
        capture.stop()
        vm.cancelCurrentTurn()
        phase = .off
    }

    /// Barge-in: cut the current reply (or pending turn) and listen again.
    /// Wired to the mic tap while in conversation mode. The running loop is
    /// awaiting `vm.sendText`; cancelling the turn makes it return and re-arm.
    func bargeIn() {
        guard isActive else { return }
        vm.cancelCurrentTurn()
    }

    // MARK: - Loop

    private func runLoop() async {
        let startedAt = Date()
        var emptyCycles = 0

        while !Task.isCancelled {
            if Date().timeIntervalSince(startedAt) > Self.maxSessionSeconds { break }

            phase = .listening
            let samples: [Float]
            do {
                samples = try await capture.listen()
            } catch is CancellationError {
                break
            } catch {
                errorMessage = error.localizedDescription
                break
            }
            if Task.isCancelled { break }

            phase = .turn
            let text = (try? await LocalTranscriber.shared.transcribe(samples: samples)) ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                emptyCycles += 1
                if emptyCycles >= Self.maxEmptyCycles { break }
                // re-arm after a brief settle (mirror the barge-in session settle)
                try? await Task.sleep(nanoseconds: 50_000_000)
                continue
            }
            emptyCycles = 0

            await vm.sendText(trimmed)   // full turn incl. on-device speak; returns when done
            if Task.isCancelled { break }

            // Stop any pending/queued spoken filler BEFORE re-arming the mic — a
            // fast or empty reply (no real `speak()` to hard-cut it) could
            // otherwise leak an instant-ack / narration phrase into the next
            // capture and self-transcribe it. Cancel the chatty heartbeat too so
            // a beat scheduled mid-turn can't fire into the next capture.
            vm.stopHeartbeat()
            LocalSpeaker.shared.stop()

            // Let the audio session settle between speaking (.playback) and the
            // next listen (.playAndRecord) — the same dirty-state guard barge-in uses.
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        capture.stop()
        phase = .off
        loopTask = nil
    }

    // MARK: - Permission

    private func ensureMicPermission() async -> Bool {
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            return await withCheckedContinuation { cont in
                AVAudioSession.sharedInstance().requestRecordPermission { cont.resume(returning: $0) }
            }
        }
    }
}
