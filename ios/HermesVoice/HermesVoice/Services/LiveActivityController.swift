import ActivityKit
import Foundation

/// Owns the single in-flight Live Activity. The app drives this from the
/// conversation state machine (and from scheduled-fire auto-play). Local
/// updates only — no push token — because the app is always running when our
/// triggers fire (foreground PTT, foreground scheduled auto-play, or
/// background-audio-active playback).
///
/// All methods are best-effort: if the user has Live Activities disabled, or
/// ActivityKit throws, we silently no-op rather than disrupt the turn.
///
/// Every ActivityKit operation runs through a serial task chain (`pending`)
/// so an `end()` always finishes before the next `request()`. Without that, a
/// fast `finish()` → `showThinking()` (e.g. a barge-in: speaking → recording →
/// thinking within tens of ms) could request a new activity while the old one
/// is still tearing down, transiently doubling up or tripping the system's
/// active-activity limit.
@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()

    private var activity: Activity<HermesActivityAttributes>?
    private var startedAt = Date()

    /// Serializes ActivityKit calls so they never overlap. Each enqueued op
    /// awaits the prior one before running.
    private var pending: Task<Void, Never>?

    /// Dead-app safety net. If the app is force-quit mid-turn, `finish()` never
    /// runs and the activity would otherwise linger on the lock screen forever.
    /// A generous stale window (refreshed on every update) lets iOS age it out.
    /// It's far longer than any single turn, so it never marks a live turn
    /// stale — distinct from `nil`, which means "never stale".
    private static let staleWindow: TimeInterval = 180

    private init() {}

    private var enabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// Start (or move to) the thinking phase. `detail` is the user's prompt
    /// when we know it (text turns); may be empty for audio turns until the
    /// reply arrives.
    func showThinking(detail: String?) {
        guard enabled else { return }
        enqueueUpsert(phase: .thinking, detail: detail ?? "")
    }

    /// Move to the speaking phase with the reply text.
    func showSpeaking(detail: String) {
        guard enabled else { return }
        enqueueUpsert(phase: .speaking, detail: detail)
    }

    /// End the activity (turn finished, errored, or interrupted).
    func finish() {
        enqueue { [weak self] in
            guard let self, let activity = self.activity else { return }
            self.activity = nil
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    // MARK: - Internals

    /// Append `op` to the serial chain so ActivityKit calls never overlap.
    private func enqueue(_ op: @escaping @MainActor () async -> Void) {
        let prior = pending
        pending = Task { @MainActor in
            await prior?.value
            await op()
        }
    }

    private func enqueueUpsert(phase: HermesActivityAttributes.Phase, detail: String) {
        enqueue { [weak self] in
            guard let self else { return }
            // Reuse the existing turn's start time so thinking → speaking
            // doesn't reset the elapsed timer; reset only when no activity is
            // live. Evaluated at execution time (after any prior teardown), so
            // it sees the up-to-date `activity`.
            if self.activity == nil { self.startedAt = Date() }
            let content = HermesActivityAttributes.ContentState(
                phase: phase, detail: detail, startedAt: self.startedAt
            )
            let staleDate = Date().addingTimeInterval(Self.staleWindow)
            if let activity = self.activity {
                await activity.update(ActivityContent(state: content, staleDate: staleDate))
            } else {
                do {
                    self.activity = try Activity.request(
                        attributes: HermesActivityAttributes(),
                        content: ActivityContent(state: content, staleDate: staleDate),
                        pushType: nil
                    )
                } catch {
                    // Most common: too many active activities, or disabled
                    // mid-flight. Best-effort — log so it's visible in device
                    // logs, then no-op.
                    print("Live Activity request failed: \(error.localizedDescription)")
                    self.activity = nil
                }
            }
        }
    }
}
