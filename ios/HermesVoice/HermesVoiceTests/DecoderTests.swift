import XCTest
@testable import HermesVoice

/// Decode inline JSON fixtures into the `HermesVoiceAPI` Decodable models and
/// assert snake_case → camelCase key mapping plus the lenient/optional defaults
/// the custom `init(from:)` decoders provide. Also exercises the SSE
/// `parseEvent` decoder (made `internal static` for testability).
final class DecoderTests: XCTestCase {
    private let decoder = JSONDecoder()

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try decoder.decode(T.self, from: Data(json.utf8))
    }

    // MARK: TurnResponse

    func testTurnResponseFullMapping() throws {
        let json = """
        {
          "session_id": "s-123",
          "user_text": "hello",
          "assistant_text": "hi back",
          "audio_url": "/api/audio/abc",
          "tool_calls": [
            {"name": "bash", "preview": "ls -la", "ok": true},
            {"name": "read", "preview": "file.txt", "ok": false}
          ]
        }
        """
        let r = try decode(HermesVoiceAPI.TurnResponse.self, json)
        XCTAssertEqual(r.sessionId, "s-123")
        XCTAssertEqual(r.userText, "hello")
        XCTAssertEqual(r.assistantText, "hi back")
        XCTAssertEqual(r.audioUrl, "/api/audio/abc")
        XCTAssertEqual(r.toolCalls.count, 2)
        XCTAssertEqual(r.toolCalls[0], HermesVoiceAPI.ToolCall(name: "bash", preview: "ls -la", ok: true))
        XCTAssertEqual(r.toolCalls[1].ok, false)
    }

    /// audio_url is optional; tool_calls absent → lenient default to empty.
    func testTurnResponseLenientDefaults() throws {
        let json = """
        {"session_id": "s", "user_text": "u", "assistant_text": "a"}
        """
        let r = try decode(HermesVoiceAPI.TurnResponse.self, json)
        XCTAssertNil(r.audioUrl)
        XCTAssertTrue(r.toolCalls.isEmpty)
    }

    /// A malformed tool_calls payload must not blow up the whole turn — the
    /// `try?` in the custom decoder swallows it to an empty list.
    func testTurnResponseToleratesBadToolCalls() throws {
        let json = """
        {"session_id": "s", "user_text": "u", "assistant_text": "a", "tool_calls": "oops"}
        """
        let r = try decode(HermesVoiceAPI.TurnResponse.self, json)
        XCTAssertTrue(r.toolCalls.isEmpty)
    }

    // MARK: HistoryMessage

    func testHistoryMessageMapping() throws {
        let json = """
        {
          "role": "assistant",
          "text": "done",
          "timestamp": 1700000000.5,
          "tool_name": "bash",
          "tool_calls": [{"name": "grep", "arguments_preview": "foo *.swift"}]
        }
        """
        let m = try decode(HermesVoiceAPI.HistoryMessage.self, json)
        XCTAssertEqual(m.role, "assistant")
        XCTAssertEqual(m.text, "done")
        XCTAssertEqual(m.timestamp, 1700000000.5)
        XCTAssertEqual(m.toolName, "bash")
        XCTAssertEqual(m.toolCalls.count, 1)
        XCTAssertEqual(m.toolCalls[0].name, "grep")
        XCTAssertEqual(m.toolCalls[0].argumentsPreview, "foo *.swift")
        // Identity is role-timestamp composed.
        XCTAssertEqual(m.id, "assistant-1700000000.5")
    }

    func testHistoryMessageOptionalDefaults() throws {
        let json = """
        {"role": "user", "text": "hi", "timestamp": 1.0}
        """
        let m = try decode(HermesVoiceAPI.HistoryMessage.self, json)
        XCTAssertNil(m.toolName)
        XCTAssertTrue(m.toolCalls.isEmpty)
    }

    // MARK: HistoryDetail

    func testHistoryDetailMapping() throws {
        let json = """
        {
          "session_id": "sess-9",
          "source": "hermes",
          "started_at": 1699999999.0,
          "title": "My Chat",
          "messages": [
            {"role": "user", "text": "q", "timestamp": 1.0},
            {"role": "assistant", "text": "a", "timestamp": 2.0}
          ]
        }
        """
        let d = try decode(HermesVoiceAPI.HistoryDetail.self, json)
        XCTAssertEqual(d.sessionId, "sess-9")
        XCTAssertEqual(d.source, "hermes")
        XCTAssertEqual(d.startedAt, 1699999999.0)
        XCTAssertEqual(d.title, "My Chat")
        XCTAssertEqual(d.messages.count, 2)
        XCTAssertEqual(d.messages[1].text, "a")
    }

    func testHistoryDetailOptionalTitle() throws {
        let json = """
        {"session_id": "s", "source": "hermes", "started_at": 0.0, "messages": []}
        """
        let d = try decode(HermesVoiceAPI.HistoryDetail.self, json)
        XCTAssertNil(d.title)
        XCTAssertTrue(d.messages.isEmpty)
    }

    // MARK: ToolCall

    func testToolCallMapping() throws {
        let json = """
        {"name": "edit", "preview": "swap line", "ok": true}
        """
        let tc = try decode(HermesVoiceAPI.ToolCall.self, json)
        XCTAssertEqual(tc, HermesVoiceAPI.ToolCall(name: "edit", preview: "swap line", ok: true))
    }

    // MARK: parseEvent (SSE)

    private func parse(_ json: String) -> HermesVoiceAPI.TurnEvent? {
        HermesVoiceAPI.parseEvent(Data(json.utf8))
    }

    func testParseEventTranscribed() {
        XCTAssertEqual(parse(#"{"type":"transcribed","text":"hello world"}"#),
                       .transcribed("hello world"))
    }

    func testParseEventTool() {
        XCTAssertEqual(
            parse(#"{"type":"tool","name":"bash","preview":"ls","ok":false}"#),
            .tool(name: "bash", preview: "ls", ok: false)
        )
    }

    /// Missing fields fall back to defaults (name "tool", ok true).
    func testParseEventToolDefaults() {
        XCTAssertEqual(parse(#"{"type":"tool"}"#),
                       .tool(name: "tool", preview: "", ok: true))
    }

    func testParseEventTools() {
        let ev = parse(#"{"type":"tools","items":[{"name":"a","preview":"p","ok":true},{"name":"b"}]}"#)
        XCTAssertEqual(ev, .tools([
            HermesVoiceAPI.ToolCall(name: "a", preview: "p", ok: true),
            HermesVoiceAPI.ToolCall(name: "b", preview: "", ok: true),
        ]))
    }

    func testParseEventAssistant() {
        XCTAssertEqual(
            parse(#"{"type":"assistant","text":"reply","session_id":"s-7"}"#),
            .assistant(text: "reply", sessionId: "s-7")
        )
    }

    func testParseEventAudioMapsUrlKey() {
        XCTAssertEqual(parse(#"{"type":"audio","url":"/api/audio/x"}"#),
                       .audio(path: "/api/audio/x"))
    }

    func testParseEventDone() {
        XCTAssertEqual(parse(#"{"type":"done","session_id":"s-9"}"#),
                       .done(sessionId: "s-9"))
    }

    func testParseEventErrorMapsToFailed() {
        XCTAssertEqual(parse(#"{"type":"error","detail":"boom"}"#),
                       .failed("boom"))
    }

    func testParseEventTurn() {
        XCTAssertEqual(parse(#"{"type":"turn","turn_id":"t-1"}"#),
                       .turn(turnId: "t-1"))
    }

    func testParseEventApprovalRequest() {
        XCTAssertEqual(
            parse(#"{"type":"approval_request","request_id":"r1","tool":"bash","title":"Run?","preview":"rm -rf"}"#),
            .approvalRequest(requestId: "r1", tool: "bash", title: "Run?", preview: "rm -rf")
        )
    }

    func testParseEventQuestion() {
        XCTAssertEqual(
            parse(#"{"type":"question","request_id":"q1","prompt":"Pick","options":["a","b"],"multi":true}"#),
            .question(requestId: "q1", prompt: "Pick", options: ["a", "b"], multi: true)
        )
    }

    func testParseEventUnknownTypeReturnsNil() {
        XCTAssertNil(parse(#"{"type":"bogus"}"#))
    }

    func testParseEventMissingTypeReturnsNil() {
        XCTAssertNil(parse(#"{"text":"no type field"}"#))
    }

    func testParseEventInvalidJSONReturnsNil() {
        XCTAssertNil(parse("not json at all"))
    }
}
