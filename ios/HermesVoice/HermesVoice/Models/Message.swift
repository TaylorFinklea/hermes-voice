import Foundation

struct ToolCallDetail: Equatable {
    let name: String
    let preview: String
    let ok: Bool
}

struct Message: Identifiable, Equatable {
    enum Role { case user, assistant, toolCall }

    let id = UUID()
    let role: Role
    var text: String
    let timestamp: Date
    var toolCall: ToolCallDetail?

    init(role: Role, text: String, timestamp: Date = .now, toolCall: ToolCallDetail? = nil) {
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.toolCall = toolCall
    }
}
