import Foundation

/// Warm, casual, first-person acknowledgments spoken on-device (AVSpeech) the
/// instant a turn is dispatched, so the user hears Hermes "pick up" before the
/// backend has produced anything. These are GENERIC acks only — the backend
/// owns per-tool narration ("Checking the weather…") via the `narrate` SSE
/// frame, so nothing here names a tool.
enum FillerPhrases {
    private static let acks = [
        "On it — let me look into that.",
        "Sure, let me check.",
        "Alright, looking that up for you.",
        "Got it — give me a sec.",
        "Okay, let me dig into that.",
        "On it — one moment.",
    ]

    /// The index of the last phrase returned, so we never repeat consecutively.
    private static var lastIndex: Int? = nil

    /// Return a warm acknowledgment, never the same one twice in a row.
    static func ack() -> String {
        guard acks.count > 1 else { return acks.first ?? "" }
        var idx = Int.random(in: 0..<acks.count)
        if let last = lastIndex {
            // Re-roll into the remaining pool so the choice is uniform over the
            // (count - 1) phrases that aren't the previous one.
            idx = Int.random(in: 0..<(acks.count - 1))
            if idx >= last { idx += 1 }
        }
        lastIndex = idx
        return acks[idx]
    }

    /// Warm "still working" phrases spoken on a periodic heartbeat during long
    /// silent gaps in a turn — only when the user picks the `chatty` verbosity.
    /// Generic (never names a tool), like `acks`.
    private static let heartbeats = [
        "Still working on it.",
        "Hang tight.",
        "Almost there.",
        "Still on it.",
        "Bear with me.",
        "Just a moment more.",
    ]

    /// The index of the last heartbeat returned, so we never repeat consecutively.
    private static var lastHeartbeatIndex: Int? = nil

    /// Return a warm "still working" phrase, never the same one twice in a row.
    static func heartbeat() -> String {
        guard heartbeats.count > 1 else { return heartbeats.first ?? "" }
        var idx = Int.random(in: 0..<heartbeats.count)
        if let last = lastHeartbeatIndex {
            // Re-roll into the remaining pool so the choice is uniform over the
            // (count - 1) phrases that aren't the previous one.
            idx = Int.random(in: 0..<(heartbeats.count - 1))
            if idx >= last { idx += 1 }
        }
        lastHeartbeatIndex = idx
        return heartbeats[idx]
    }
}
