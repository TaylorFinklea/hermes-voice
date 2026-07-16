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

        // MARK: race-test gates (inert unless a test opts in)

        /// Gate `getSession`: when true, it signals entry then suspends until
        /// `releaseGetSession()` before returning `sessionResult`. Lets a test
        /// cancel/switch the turn while History recovery is mid-flight.
        var gateGetSession = false
        private var getSessionDidEnter = false
        private var getSessionEnteredCont: CheckedContinuation<Void, Never>?
        private var getSessionReleaseCont: CheckedContinuation<Void, Never>?

        func awaitGetSessionEntered() async {
            if getSessionDidEnter { return }
            await withCheckedContinuation { getSessionEnteredCont = $0 }
        }
        func releaseGetSession() {
            getSessionReleaseCont?.resume()
            getSessionReleaseCont = nil
        }

        /// Gate `streamText` from the Nth call (1-based): a gated call stores its
        /// continuation and never yields, so the turn stays suspended in
        /// `.thinking` until `releaseStream()` finishes it — throwing
        /// `gateStreamError` when set, else finishing cleanly.
        var gateStreamFromCall: Int?
        var gateStreamError: Error?
        private var streamCallCount = 0
        private var streamDidEnter = false
        private var streamEnteredCont: CheckedContinuation<Void, Never>?
        private var streamReleaseCont: AsyncThrowingStream<HermesVoiceAPI.TurnEvent, Error>.Continuation?

        func awaitStreamEntered() async {
            if streamDidEnter { return }
            await withCheckedContinuation { streamEnteredCont = $0 }
        }
        func releaseStream() {
            if let gateStreamError {
                streamReleaseCont?.finish(throwing: gateStreamError)
            } else {
                streamReleaseCont?.finish()
            }
            streamReleaseCont = nil
        }

        func streamText(
            _ text: String, sessionId: String?, voiceId: String?, tts: String?, harness: String?, mode: String?
        ) -> AsyncThrowingStream<HermesVoiceAPI.TurnEvent, Error> {
            streamCallCount += 1
            if let gateStreamFromCall, streamCallCount >= gateStreamFromCall {
                return AsyncThrowingStream { continuation in
                    self.streamReleaseCont = continuation
                    self.streamDidEnter = true
                    self.streamEnteredCont?.resume()
                    self.streamEnteredCont = nil
                }
            }
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
            if gateGetSession {
                getSessionDidEnter = true
                getSessionEnteredCont?.resume()
                getSessionEnteredCont = nil
                await withCheckedContinuation { getSessionReleaseCont = $0 }
            }
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
    /// path never reaches `LocalSpeaker`/`player`. Backed by a unique
    /// UserDefaults suite (mirrors `BackendProfileTests`' pattern) so tests
    /// don't write profile + legacy keys into the test host's standard
    /// defaults.
    private func makeSettings() -> AppSettings {
        let suite = "TurnStateMachineTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let s = AppSettings(defaults: defaults)
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

    func testSwitchBackendClearsConversationBeforeNextTurn() throws {
        let settings = makeSettings()
        let other = BackendProfile(name: "Laptop B", url: "https://b.example:8765", authToken: "b", selectedHarness: "codex")
        settings.saveProfile(other)
        let vm = ConversationViewModel(settings: settings, transport: FakeTransport())
        vm.attach(sessionId: "session-a", harness: "claude", repo: "/tmp/repo", readOnly: true)

        XCTAssertTrue(vm.switchBackend(to: other.id))
        XCTAssertEqual(settings.activeBackendProfile.id, other.id)
        XCTAssertEqual(settings.selectedHarness, "codex")
        XCTAssertNil(vm.sessionId)
        XCTAssertTrue(vm.messages.isEmpty)
        XCTAssertNil(vm.attachedRepo)
    }

    func testSwitchBackendRejectedWhileApprovalPending() async throws {
        let settings = makeSettings()
        let other = BackendProfile(name: "Laptop B", url: "https://b.example:8765", authToken: "b", selectedHarness: "codex")
        settings.saveProfile(other)
        let originalId = settings.activeBackendProfile.id

        let fake = FakeTransport()
        // No `.done`/`.assistant` after the approval request — the stream
        // just ends, so state settles back to `.idle` while the approval
        // itself stays pending (nothing answers it). Exercises the
        // `canSwitchBackend` guard's pendingApproval check independently of
        // `state`.
        fake.textEvents = [
            .turn(turnId: "t-1"),
            .approvalRequest(requestId: "r-1", tool: "edit_file", title: "Edit config.py", preview: "…"),
        ]
        let vm = ConversationViewModel(settings: settings, transport: fake)

        await vm.sendText("do something risky")

        XCTAssertNotNil(vm.pendingApproval, "approval request should still be pending")
        XCTAssertFalse(vm.canSwitchBackend)
        XCTAssertFalse(vm.switchBackend(to: other.id))
        XCTAssertEqual(settings.activeBackendProfile.id, originalId)
    }

    /// Regression for the generation-safe teardown fix: a turn task cancelled by
    /// `switchBackend` while its History recovery await is in flight must NOT
    /// clobber a *new* turn's `.thinking` back to `.idle`, nor append the reply
    /// it recovered for the now-abandoned conversation.
    func testRecoveryRaceDoesNotClobberNewTurnState() async throws {
        let settings = makeSettings()
        let other = BackendProfile(name: "Laptop B", url: "https://b.example:8765", authToken: "b", selectedHarness: "codex")
        settings.saveProfile(other)

        let fake = FakeTransport()
        // Turn 1: a clean stream carrying a session id but no assistant → the
        // History-recovery path runs. Its `getSession` is gated so we can
        // interleave a switch while recovery is blocked.
        fake.textEvents = [.done(sessionId: "s-1")]
        fake.gateGetSession = true
        fake.sessionResult = .success(try decode(
            HermesVoiceAPI.HistoryDetail.self,
            """
            {"session_id":"s-1","source":"hermes","started_at":0,"messages":[
              {"role":"user","text":"q1","timestamp":1},
              {"role":"assistant","text":"SHOULD NOT APPEAR","timestamp":2}
            ]}
            """
        ))
        // The 2nd streamText call (the "new turn") is gated open so it parks in
        // `.thinking` while the cancelled turn 1 unwinds.
        fake.gateStreamFromCall = 2

        let vm = ConversationViewModel(settings: settings, transport: fake)

        // Turn 1 drives to the recovery await and blocks in `getSession`.
        let turn1 = Task { await vm.sendText("q1") }
        await fake.awaitGetSessionEntered()

        // `.done` already settled state to `.idle`, so the switch is allowed and
        // cancels turn 1's task.
        XCTAssertTrue(vm.switchBackend(to: other.id))

        // New turn: `sendText` drives `.thinking`; its gated stream keeps it there.
        let turn2 = Task { await vm.sendText("q2") }
        await fake.awaitStreamEntered()
        XCTAssertEqual(vm.state, .thinking)

        // Release turn 1's recovery. The cancelled task must leave state alone.
        fake.releaseGetSession()
        await turn1.value

        XCTAssertEqual(vm.state, .thinking, "cancelled turn's recovery tail must not settle a live turn to idle")
        XCTAssertFalse(vm.messages.contains { $0.text == "SHOULD NOT APPEAR" },
                       "cancelled turn must not append its recovered assistant reply")
        XCTAssertEqual(vm.messages.map(\.text), ["q2"])

        // Cleanup: let turn 2 finish so its task doesn't outlive the test.
        fake.releaseStream()
        await turn2.value
    }

    /// Companion to the 404 single-shot fallback: a turn cancelled before the
    /// fallback fires must NOT re-POST the prompt (which `api` would send to the
    /// CURRENT — possibly switched — backend). Asserts the observable contract:
    /// no `sendText` single-shot call happens for a cancelled 404 turn.
    ///
    /// NOTE: with an `AsyncThrowingStream`-backed fake, task cancellation
    /// terminates the stream, so this exercises the "cancelled turn does not
    /// re-POST" behavior without pinning down whether the `!Task.isCancelled`
    /// guard or the stream-termination path suppressed it — both are correct and
    /// both are what the fix protects. The guard remains defense-in-depth for the
    /// real SSE transport, where a buffered 404 can race a URLSession cancel.
    func testCancelledTurnDoesNotFireSingleShotFallback() async throws {
        let fake = FakeTransport()
        // The 1st (only) streamText call is gated, then released with a 404.
        fake.gateStreamFromCall = 1
        fake.gateStreamError = HermesVoiceAPI.APIError.httpStatus(404, "")
        // If the fallback ever fired, this would be delivered and observed.
        fake.sendTextResult = .success(try decode(
            HermesVoiceAPI.TurnResponse.self,
            #"{"session_id":"s-9","user_text":"q","assistant_text":"SHOULD NOT POST","tool_calls":[]}"#
        ))
        let vm = ConversationViewModel(settings: makeSettings(), transport: fake)

        let turn = Task { await vm.sendText("q") }
        await fake.awaitStreamEntered()
        XCTAssertEqual(vm.state, .thinking)

        // Cancel the in-flight turn, THEN surface the 404.
        vm.cancelCurrentTurn()
        fake.releaseStream()
        await turn.value

        XCTAssertFalse(fake.sendTextCalled, "a cancelled 404 turn must not re-POST via the single-shot fallback")
        XCTAssertFalse(vm.messages.contains { $0.text == "SHOULD NOT POST" })
    }
}
