import XCTest
@testable import HermesVoice

/// Pure-logic coverage for `pairedTurns(in:)` / `TurnPair` (Views/MainView.swift):
/// the flat message list → user/tool*/assistant grouping that drives the
/// scrollback rail. No view model or singletons touched, so no actor isolation
/// is needed here.
final class PairedTurnsTests: XCTestCase {
    private func user(_ text: String) -> Message { Message(role: .user, text: text) }
    private func assistant(_ text: String) -> Message { Message(role: .assistant, text: text) }
    private func tool(_ name: String) -> Message {
        Message(
            role: .toolCall,
            text: name,
            toolCall: ToolCallDetail(name: name, preview: "", ok: true)
        )
    }

    func testEmptyMessagesYieldsNoPairs() {
        XCTAssertTrue(pairedTurns(in: []).isEmpty)
    }

    /// A leading assistant/tool message with no preceding user is skipped — a
    /// turn only opens on a `.user` message.
    func testOrphanLeadingMessagesAreSkipped() {
        let pairs = pairedTurns(in: [assistant("hi there"), tool("read")])
        XCTAssertTrue(pairs.isEmpty)
    }

    /// A user message with nothing after it still forms one pair (no tools, no
    /// assistant reply yet).
    func testUserOnlyTurn() {
        let pairs = pairedTurns(in: [user("hello")])
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].userMessage.text, "hello")
        XCTAssertTrue(pairs[0].toolMessages.isEmpty)
        XCTAssertEqual(pairs[0].toolCount, 0)
        XCTAssertNil(pairs[0].assistantMessage)
    }

    /// User → tools but no assistant: the turn captures the tools with a nil
    /// assistant (still in flight / no reply).
    func testToolOnlyTurnMissingAssistant() {
        let pairs = pairedTurns(in: [user("do work"), tool("bash"), tool("read")])
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].toolCount, 2)
        XCTAssertEqual(pairs[0].toolMessages.map(\.text), ["bash", "read"])
        XCTAssertNil(pairs[0].assistantMessage)
    }

    func testFullSingleTurn() {
        let pairs = pairedTurns(in: [user("q"), tool("grep"), assistant("a")])
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].userMessage.text, "q")
        XCTAssertEqual(pairs[0].toolCount, 1)
        XCTAssertEqual(pairs[0].assistantMessage?.text, "a")
    }

    /// Multi-turn sequence: each user starts a fresh pair, tools/assistant
    /// attach to the most recent user.
    func testMultiTurnSequence() {
        let messages = [
            user("first"), tool("t1"), assistant("reply1"),
            user("second"), assistant("reply2"),
            user("third"), tool("t3a"), tool("t3b"), assistant("reply3"),
        ]
        let pairs = pairedTurns(in: messages)
        XCTAssertEqual(pairs.count, 3)

        XCTAssertEqual(pairs[0].userMessage.text, "first")
        XCTAssertEqual(pairs[0].toolCount, 1)
        XCTAssertEqual(pairs[0].assistantMessage?.text, "reply1")

        XCTAssertEqual(pairs[1].userMessage.text, "second")
        XCTAssertEqual(pairs[1].toolCount, 0)
        XCTAssertEqual(pairs[1].assistantMessage?.text, "reply2")

        XCTAssertEqual(pairs[2].userMessage.text, "third")
        XCTAssertEqual(pairs[2].toolCount, 2)
        XCTAssertEqual(pairs[2].assistantMessage?.text, "reply3")
    }

    /// Trailing tools after the last assistant (or with no assistant) stay
    /// attached to the open turn rather than spawning a new pair.
    func testTrailingToolsAfterAssistant() {
        let messages = [
            user("go"), assistant("ok"), tool("late1"), tool("late2"),
        ]
        let pairs = pairedTurns(in: messages)
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].assistantMessage?.text, "ok")
        // Both the pre- and post-assistant tools collapse into the same turn.
        XCTAssertEqual(pairs[0].toolCount, 2)
        XCTAssertEqual(pairs[0].toolMessages.map(\.text), ["late1", "late2"])
    }

    /// When two assistant messages appear in one turn, the LAST one wins (the
    /// loop overwrites `assistant`).
    func testLastAssistantWinsWithinTurn() {
        let pairs = pairedTurns(in: [user("q"), assistant("draft"), assistant("final")])
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].assistantMessage?.text, "final")
    }
}
