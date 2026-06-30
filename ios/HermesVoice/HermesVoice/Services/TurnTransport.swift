import Foundation

/// The backend surface the `ConversationViewModel` depends on — every `api.*`
/// call the turn flow makes, behind one protocol so the VM's turn state machine
/// can be driven by a fake in tests (see `TurnStateMachineTests`).
///
/// Deliberately NARROW: it mirrors only what the VM uses, not the whole
/// `HermesVoiceAPI`. The 13 other ad-hoc `HermesVoiceAPI(...)` call sites and
/// the DTOs (still nested in `HermesVoiceAPI`) are untouched. Each requirement
/// matches a concrete `HermesVoiceAPI` method exactly, so conformance is an
/// empty extension and production behavior is unchanged.
protocol TurnTransport {
    func streamText(
        _ text: String, sessionId: String?, voiceId: String?, tts: String?, harness: String?, mode: String?
    ) -> AsyncThrowingStream<HermesVoiceAPI.TurnEvent, Error>

    func streamAudio(
        fileURL: URL, mimeType: String, sessionId: String?, voiceId: String?, tts: String?, harness: String?, mode: String?
    ) -> AsyncThrowingStream<HermesVoiceAPI.TurnEvent, Error>

    func sendText(
        _ text: String, sessionId: String?, voiceId: String?, tts: String?, harness: String?
    ) async throws -> HermesVoiceAPI.TurnResponse

    func sendAudio(
        fileURL: URL, mimeType: String, sessionId: String?, voiceId: String?, tts: String?, harness: String?
    ) async throws -> HermesVoiceAPI.TurnResponse

    func getSession(id: String) async throws -> HermesVoiceAPI.HistoryDetail

    func answerTurn(turnId: String, requestId: String, value: Any) async throws

    func makeURL(path: String) -> URL?
}

/// Existing signatures already satisfy the protocol — the body is intentionally empty.
extension HermesVoiceAPI: TurnTransport {}
