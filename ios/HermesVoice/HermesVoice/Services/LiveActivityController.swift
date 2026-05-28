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
@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()

    private var activity: Activity<HermesActivityAttributes>?
    private var startedAt = Date()

    private init() {}

    private var enabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// Start (or move to) the thinking phase. `detail` is the user's prompt
    /// when we know it (text turns); may be empty for audio turns until the
    /// reply arrives.
    func showThinking(detail: String?) {
        guard enabled else { return }
        let content = HermesActivityAttributes.ContentState(
            phase: .thinking,
            detail: detail ?? "",
            startedAt: existingOrNewStart()
        )
        upsert(content)
    }

    /// Move to the speaking phase with the reply text.
    func showSpeaking(detail: String) {
        guard enabled else { return }
        let content = HermesActivityAttributes.ContentState(
            phase: .speaking,
            detail: detail,
            startedAt: existingOrNewStart()
        )
        upsert(content)
    }

    /// End the activity (turn finished, errored, or interrupted).
    func finish() {
        guard let activity else { return }
        self.activity = nil
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    // MARK: - Internals

    /// Reuse the existing turn's start time so the elapsed timer doesn't reset
    /// when we transition thinking → speaking. Resets when no activity is live.
    private func existingOrNewStart() -> Date {
        if activity == nil { startedAt = Date() }
        return startedAt
    }

    private func upsert(_ content: HermesActivityAttributes.ContentState) {
        if let activity {
            Task { await activity.update(ActivityContent(state: content, staleDate: nil)) }
        } else {
            do {
                activity = try Activity.request(
                    attributes: HermesActivityAttributes(),
                    content: ActivityContent(state: content, staleDate: nil),
                    pushType: nil
                )
            } catch {
                // Most common: too many active activities, or disabled mid-flight.
                activity = nil
            }
        }
    }
}
