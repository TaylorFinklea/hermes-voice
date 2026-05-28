import ActivityKit
import Foundation

/// Shared between the app (which starts/updates/ends the activity) and the
/// widget extension (which renders it). ActivityKit requires this exact type
/// to be compiled into both targets — it's added to the widget target's
/// sources explicitly in project.yml.
struct HermesActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: Phase
        var detail: String     // current user prompt (thinking) or reply (speaking)
        var startedAt: Date    // anchor for the elapsed timer
    }

    enum Phase: String, Codable, Hashable {
        case thinking
        case speaking

        var label: String {
            switch self {
            case .thinking: return "THINKING…"
            case .speaking: return "SPEAKING"
            }
        }
    }
}
