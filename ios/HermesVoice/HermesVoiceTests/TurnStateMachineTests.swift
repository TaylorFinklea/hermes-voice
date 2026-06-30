import XCTest
@testable import HermesVoice

/// Drives the `ConversationViewModel` turn state machine through the injected
/// `TurnTransport` seam — the coverage that was blocked until the VM had an
/// injection point. A `FakeTransport` returns scripted SSE event streams (and
/// scripted single-shot / history results), so we can assert state transitions,
/// transcript commits, the tool→tools authoritative swap, the 404 single-shot
/// fallback, History recovery, and the failure path — all without a network or
/// audio.
///
/// All tests use the `sendText` entry (no recorder/transcriber) and a server
/// (non-local) voice with filler off, so `LocalSpeaker`/`player` are never
/// touched (no `audio` events are scripted).
@MainActor
final class TurnStateMachineTests: XCTestCase {

    // MARK: - Test double

    /// A scripted `TurnTransport`. Captures only what the VM's turn path calls.
    final class FakeTransport: TurnTransport, @unchecked Sendable {
        /// Events yielded by `streamText` before it finishes.
        var textEvents: [HermesVoiceAPI.TurnEvent] = []
        /// If set, `streamText` finishes by throwing this (after yielding `textEvents`).
        var streamError: Error?
        /// Result for the single-shot `sendText` fallback.
        var sendTextResult: Result<HermesVoiceAPI.TurnResponse, Error>?
        /// Result for the `getSession` History-recovery call.
        var sessionResult: Result<HermesVoiceAPI.HistoryDetail, Error>?

        private(set) var sendTextCalled = false
        private(set) var getSessionCalled = false

        func streamText(
            _ text: String, sessionId: String?, voiceId: String?, tts: String?, harness: String?, mode: String?
        ) -> AsyncThrowingStream<HermesVoiceAPI.TurnEvent, Error> {
            let events = textEvents
            let error = streamError
            return AsyncThrowingStream { continuation in
                for ev in events { continuation.yield(ev) }
                continuation.finish(throwing: error)
            }
        }

        func streamAudio(
            fileURL: URL, mimeType: String, sessionId: String?, voiceId: String?, tts: String?, harness: String?, mode: String?
        ) -> AsyncThrowingStream<HermesVoiceAPI.TurnEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }

        func sendText(
            _ text: String, sessionId: String?, voiceId: String?, tts: String?, harness: String?
        ) async throws -> HermesVoiceAPI.TurnResponse {
            sendTextCalled = true
            switch sendTextResult {
            case .success(let r): return r
            case .failure(let e): throw e
            case nil: throw HermesVoiceAPI.APIError.badURL
            }
        }

        func sendAudio(
            fileURL: URL, mimeType: String, sessionId: String?, voiceId: String?, tts: String?, harness: String?
        ) async throws -> HermesVoiceAPI.TurnResponse {
            throw HermesVoiceAPI.APIError.badURL
        }

        func getSession(id: String) async throws -> HermesVoiceAPI.HistoryDetail {
            getSessionCalled = true
            switch sessionResult {
            case .success(let d): return d
            case .failure(let e): throw e
            case nil: throw HermesVoiceAPI.APIError.badURL
            }
        }

        func answerTurn(turnId: String, requestId: String, value: Any) async throws {}

        func makeURL(path: String) -> URL? { URL(string: "https://example.invalid/\(path)") }
    }

    // MARK: - Helpers

    /// A settings object pinned to a server voice with filler off, so the turn
    /// path never reaches `LocalSpeaker`/`player`.
    private func makeSettings() -> AppSettings {
        let s = AppSettings()
        s.selectedVoiceId = "elevenlabs-rachel"  // non-"local:" → server voice
        s.fillerVerbosity = .off
        return s
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: - Tests

    func testHappyPathCommitsReplyAndReturnsToIdle() async throws {
        let fake = FakeTransport()
        fake.textEvents = [
            .assistant(text: "Hi there", sessionId: "s-1"),
            .done(sessionId: "s-1"),
        ]
        let vm = ConversationViewModel(settings: makeSettings(), transport: fake)

        await vm.sendText("hello")

        XCTAssertEqual(vm.state, .idle)
        XCTAssertEqual(vm.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(vm.messages.map(\.text), ["hello", "Hi there"])
        XCTAssertEqual(vm.sessionId, "s-1")
    }

    func testToolsEventReplacesLiveToolChips() async throws {
        let authoritative = try decode(
            HermesVoiceAPI.ToolCall.self,
            #"{"name":"search","preview":"final","ok":true}"#
        )
        let fake = FakeTransport()
        fake.textEvents = [
            .tool(name: "search", preview: "partial", ok: true),   // live best-effort chip
            .tools([authoritative]),                                // authoritative swap
            .assistant(text: "done", sessionId: "s-1"),
            .done(sessionId: "s-1"),
        ]
        let vm = ConversationViewModel(settings: makeSettings(), transport: fake)

        await vm.sendText("hello")

        // Exactly one tool chip survives (the authoritative one), between user + assistant.
        XCTAssertEqual(vm.messages.map(\.role), [.user, .toolCall, .assistant])
        let chip = try XCTUnwrap(vm.messages.first { $0.role == .toolCall })
        XCTAssertEqual(chip.toolCall?.preview, "final")
        XCTAssertEqual(vm.state, .idle)
    }

    func test404FallsBackToSingleShotAndCommitsReply() async throws {
        let fake = FakeTransport()
        fake.streamError = HermesVoiceAPI.APIError.httpStatus(404, "")
        fake.sendTextResult = .success(try decode(
            HermesVoiceAPI.TurnResponse.self,
            #"{"session_id":"s-2","user_text":"hello","assistant_text":"Recovered via POST","tool_calls":[]}"#
        ))
        let vm = ConversationViewModel(settings: makeSettings(), transport: fake)

        await vm.sendText("hello")

        XCTAssertTrue(fake.sendTextCalled, "404 on the stream should trigger the single-shot fallback")
        XCTAssertEqual(vm.messages.last?.role, .assistant)
        XCTAssertEqual(vm.messages.last?.text, "Recovered via POST")
        XCTAssertEqual(vm.state, .idle)
    }

    func testCleanStreamWithNoAssistantRecoversFromHistory() async throws {
        let fake = FakeTransport()
        // Stream completes with a session id but never sends `assistant`.
        fake.textEvents = [.done(sessionId: "s-3")]
        fake.sessionResult = .success(try decode(
            HermesVoiceAPI.HistoryDetail.self,
            """
            {"session_id":"s-3","source":"hermes","started_at":0,"messages":[
              {"role":"user","text":"hello","timestamp":1},
              {"role":"assistant","text":"Backfilled from history","timestamp":2}
            ]}
            """
        ))
        let vm = ConversationViewModel(settings: makeSettings(), transport: fake)

        await vm.sendText("hello")

        XCTAssertTrue(fake.getSessionCalled, "a clean stream with no assistant should query History")
        XCTAssertEqual(vm.messages.last?.role, .assistant)
        XCTAssertEqual(vm.messages.last?.text, "Backfilled from history")
        XCTAssertEqual(vm.state, .idle)
    }

    func testMidStreamErrorWithNoSessionFailsTheTurn() async throws {
        let fake = FakeTransport()
        // Non-HTTP error, first turn (no session) → recovery is skipped → failTurn.
        fake.streamError = URLError(.timedOut)
        let vm = ConversationViewModel(settings: makeSettings(), transport: fake)

        await vm.sendText("hello")

        XCTAssertFalse(fake.getSessionCalled, "no session id → History recovery is skipped")
        // User message stays; no assistant reply was surfaced.
        XCTAssertEqual(vm.messages.map(\.role), [.user])
        guard case .error = vm.state else {
            return XCTFail("expected .error, got \(vm.state)")
        }
    }
}
