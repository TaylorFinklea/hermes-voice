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
}
