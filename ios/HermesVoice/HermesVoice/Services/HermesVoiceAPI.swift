import Foundation

/// Thin HTTP client for the backend. All calls are async/await on URLSession.
struct HermesVoiceAPI {
    struct ToolCall: Decodable, Equatable {
        let name: String
        let preview: String
        let ok: Bool
    }

    struct TurnResponse: Decodable, Equatable {
        let sessionId: String
        let userText: String
        let assistantText: String
        let audioUrl: String?
        let toolCalls: [ToolCall]

        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case userText = "user_text"
            case assistantText = "assistant_text"
            case audioUrl = "audio_url"
            case toolCalls = "tool_calls"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sessionId = try c.decode(String.self, forKey: .sessionId)
            userText = try c.decode(String.self, forKey: .userText)
            assistantText = try c.decode(String.self, forKey: .assistantText)
            audioUrl = try c.decodeIfPresent(String.self, forKey: .audioUrl)
            toolCalls = (try? c.decode([ToolCall].self, forKey: .toolCalls)) ?? []
        }
    }

    enum APIError: LocalizedError {
        case badURL
        case httpStatus(Int, String)
        case decode(Error)
        case transport(Error)

        var errorDescription: String? {
            switch self {
            case .badURL: return "Invalid backend URL."
            case .httpStatus(let code, let body):
                return "Backend returned \(code): \(body)"
            case .decode(let e): return "Could not decode backend response: \(e.localizedDescription)"
            case .transport(let e): return "Network error: \(e.localizedDescription)"
            }
        }
    }

    var baseURL: String
    var authToken: String
    var session: URLSession = .shared

    func health() async throws -> [String: Any] {
        let url = try buildURL("/health")
        let (data, response) = try await perform(URLRequest(url: url))
        try Self.ensureOK(response, data: data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.decode(NSError(domain: "HermesVoiceAPI", code: -1))
        }
        return json
    }

    func sendText(_ text: String, sessionId: String?, voiceId: String? = nil, tts: String? = nil, harness: String? = nil) async throws -> TurnResponse {
        let url = try buildURL("/api/text")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = ["text": text]
        if let sessionId, !sessionId.isEmpty { payload["session_id"] = sessionId }
        if let voiceId, !voiceId.isEmpty { payload["voice_id"] = voiceId }
        if let tts, !tts.isEmpty { payload["tts"] = tts }
        if let harness, !harness.isEmpty { payload["harness"] = harness }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await perform(req)
        try Self.ensureOK(response, data: data)
        return try Self.decoder.decode(TurnResponse.self, from: data)
    }

    func sendAudio(fileURL: URL, mimeType: String, sessionId: String?, voiceId: String? = nil, tts: String? = nil, harness: String? = nil) async throws -> TurnResponse {
        let url = try buildURL("/api/audio")
        let boundary = "----HermesVoiceBoundary\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audio = try Data(contentsOf: fileURL)
        var body = Data()
        let crlf = "\r\n"

        func appendPart(name: String, filename: String? = nil, contentType: String? = nil, data: Data) {
            body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
            var disposition = "Content-Disposition: form-data; name=\"\(name)\""
            if let filename { disposition += "; filename=\"\(filename)\"" }
            body.append("\(disposition)\(crlf)".data(using: .utf8)!)
            if let contentType {
                body.append("Content-Type: \(contentType)\(crlf)".data(using: .utf8)!)
            }
            body.append(crlf.data(using: .utf8)!)
            body.append(data)
            body.append(crlf.data(using: .utf8)!)
        }

        appendPart(
            name: "file",
            filename: fileURL.lastPathComponent,
            contentType: mimeType,
            data: audio
        )
        if let sessionId, !sessionId.isEmpty {
            appendPart(name: "session_id", data: sessionId.data(using: .utf8)!)
        }
        if let voiceId, !voiceId.isEmpty {
            appendPart(name: "voice_id", data: voiceId.data(using: .utf8)!)
        }
        if let tts, !tts.isEmpty {
            appendPart(name: "tts", data: tts.data(using: .utf8)!)
        }
        if let harness, !harness.isEmpty {
            appendPart(name: "harness", data: harness.data(using: .utf8)!)
        }
        body.append("--\(boundary)--\(crlf)".data(using: .utf8)!)

        let (data, response) = try await perform(req, body: body)
        try Self.ensureOK(response, data: data)
        return try Self.decoder.decode(TurnResponse.self, from: data)
    }

    // MARK: - Conversation history

    struct HistorySession: Decodable, Identifiable, Equatable {
        var id: String { sessionId }
        let sessionId: String
        let source: String
        let startedAt: Double
        let messageCount: Int
        let toolCallCount: Int
        let preview: String

        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case source
            case startedAt = "started_at"
            case messageCount = "message_count"
            case toolCallCount = "tool_call_count"
            case preview
        }
    }

    struct HistoryToolCall: Decodable, Equatable {
        let name: String
        let argumentsPreview: String

        enum CodingKeys: String, CodingKey {
            case name
            case argumentsPreview = "arguments_preview"
        }
    }

    struct HistoryMessage: Decodable, Identifiable, Equatable {
        /// Stable id for SwiftUI ForEach. Timestamp + role usually unique
        /// enough within a session.
        var id: String { "\(role)-\(timestamp)" }
        let role: String
        let text: String
        let timestamp: Double
        let toolName: String?
        let toolCalls: [HistoryToolCall]

        enum CodingKeys: String, CodingKey {
            case role, text, timestamp
            case toolName = "tool_name"
            case toolCalls = "tool_calls"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            role = try c.decode(String.self, forKey: .role)
            text = try c.decode(String.self, forKey: .text)
            timestamp = try c.decode(Double.self, forKey: .timestamp)
            toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
            toolCalls = (try? c.decode([HistoryToolCall].self, forKey: .toolCalls)) ?? []
        }
    }

    struct HistoryDetail: Decodable, Equatable {
        let sessionId: String
        let source: String
        let startedAt: Double
        let title: String?
        let messages: [HistoryMessage]

        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case source
            case startedAt = "started_at"
            case title
            case messages
        }
    }

    func listSessions(limit: Int = 30) async throws -> [HistorySession] {
        let url = try buildURL("/api/sessions?limit=\(limit)")
        let (data, response) = try await perform(URLRequest(url: url))
        try Self.ensureOK(response, data: data)
        do {
            return try Self.decoder.decode([HistorySession].self, from: data)
        } catch {
            throw APIError.decode(error)
        }
    }

    func getSession(id: String) async throws -> HistoryDetail {
        let url = try buildURL("/api/sessions/\(id)")
        let (data, response) = try await perform(URLRequest(url: url))
        try Self.ensureOK(response, data: data)
        do {
            return try Self.decoder.decode(HistoryDetail.self, from: data)
        } catch {
            throw APIError.decode(error)
        }
    }

    // MARK: - Schedules

    struct Schedule: Decodable, Identifiable, Equatable {
        let id: String
        let cadenceSeconds: Int
        let prompt: String
        let displayName: String?
        let createdAt: Double
        let lastFiredAt: Double?
        let nextFireAt: Double
        let enabled: Bool
        let consecutiveFails: Int
        let source: String

        enum CodingKeys: String, CodingKey {
            case id
            case cadenceSeconds = "cadence_seconds"
            case prompt
            case displayName = "display_name"
            case createdAt = "created_at"
            case lastFiredAt = "last_fired_at"
            case nextFireAt = "next_fire_at"
            case enabled
            case consecutiveFails = "consecutive_fails"
            case source
        }
    }

    func listSchedules() async throws -> [Schedule] {
        let url = try buildURL("/api/schedules")
        let (data, response) = try await perform(URLRequest(url: url))
        try Self.ensureOK(response, data: data)
        do {
            return try Self.decoder.decode([Schedule].self, from: data)
        } catch {
            throw APIError.decode(error)
        }
    }

    func createSchedule(
        cadenceSeconds: Int, prompt: String, displayName: String?
    ) async throws -> Schedule {
        let url = try buildURL("/api/schedules")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = [
            "cadence_seconds": cadenceSeconds,
            "prompt": prompt,
        ]
        if let displayName, !displayName.isEmpty {
            payload["display_name"] = displayName
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await perform(req)
        try Self.ensureOK(response, data: data)
        do {
            return try Self.decoder.decode(Schedule.self, from: data)
        } catch {
            throw APIError.decode(error)
        }
    }

    func updateSchedule(
        id: String,
        cadenceSeconds: Int? = nil,
        prompt: String? = nil,
        displayName: String? = nil,
        enabled: Bool? = nil
    ) async throws -> Schedule {
        let url = try buildURL("/api/schedules/\(id)")
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = [:]
        if let cadenceSeconds { payload["cadence_seconds"] = cadenceSeconds }
        if let prompt { payload["prompt"] = prompt }
        if let displayName { payload["display_name"] = displayName }
        if let enabled { payload["enabled"] = enabled }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await perform(req)
        try Self.ensureOK(response, data: data)
        do {
            return try Self.decoder.decode(Schedule.self, from: data)
        } catch {
            throw APIError.decode(error)
        }
    }

    func deleteSchedule(id: String) async throws {
        let url = try buildURL("/api/schedules/\(id)")
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        let (data, response) = try await perform(req)
        try Self.ensureOK(response, data: data)
    }

    // MARK: - Devices (Phase B push registration)

    struct DeviceResponse: Decodable {
        let token: String
        let platform: String
        let bundleId: String
        let environment: String
        let registeredAt: Double
        let lastSeenAt: Double

        enum CodingKeys: String, CodingKey {
            case token, platform, environment
            case bundleId = "bundle_id"
            case registeredAt = "registered_at"
            case lastSeenAt = "last_seen_at"
        }
    }

    func registerDevice(
        token: String, platform: String, bundleId: String, environment: String
    ) async throws -> DeviceResponse {
        let url = try buildURL("/api/devices")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "token": token,
            "platform": platform,
            "bundle_id": bundleId,
            "environment": environment,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await perform(req)
        try Self.ensureOK(response, data: data)
        do {
            return try Self.decoder.decode(DeviceResponse.self, from: data)
        } catch {
            throw APIError.decode(error)
        }
    }

    func unregisterDevice(token: String) async throws {
        let url = try buildURL("/api/devices/\(token)")
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        let (data, response) = try await perform(req)
        try Self.ensureOK(response, data: data)
    }

    func replayAudio(text: String, voiceId: String? = nil) async throws -> String {
        let url = try buildURL("/api/replay")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = ["text": text]
        if let voiceId, !voiceId.isEmpty { payload["voice_id"] = voiceId }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await perform(req)
        try Self.ensureOK(response, data: data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = json["audio_url"] as? String else {
            throw APIError.decode(NSError(domain: "HermesVoiceAPI", code: -1))
        }
        return path
    }

    // MARK: - Streaming turns (SSE)

    /// One server-sent event from a streaming turn. The reply + final tool list
    /// are authoritative (from the session export); `tool` events are the live,
    /// best-effort feed parsed from Hermes's stdout as it works.
    enum TurnEvent: Equatable {
        case transcribed(String)
        case tool(name: String, preview: String, ok: Bool)
        case tools([ToolCall])
        case assistant(text: String, sessionId: String)
        case audio(path: String)
        case done(sessionId: String)
        case failed(String)
        // Phase B: bidirectional approval/question events. `turn` carries the
        // turn_id the client POSTs answers to; approvalRequest/question pause the
        // turn until the user answers.
        case turn(turnId: String)
        case approvalRequest(requestId: String, tool: String, title: String, preview: String)
        case question(requestId: String, prompt: String, options: [String], multi: Bool)
    }

    func streamText(
        _ text: String, sessionId: String?, voiceId: String? = nil, tts: String? = nil, harness: String? = nil, mode: String? = nil
    ) -> AsyncThrowingStream<TurnEvent, Error> {
        var payload: [String: Any] = ["text": text]
        if let sessionId, !sessionId.isEmpty { payload["session_id"] = sessionId }
        if let voiceId, !voiceId.isEmpty { payload["voice_id"] = voiceId }
        if let tts, !tts.isEmpty { payload["tts"] = tts }
        if let harness, !harness.isEmpty { payload["harness"] = harness }
        if let mode, !mode.isEmpty { payload["mode"] = mode }
        return events(path: "/api/text/stream", jsonBody: payload)
    }

    func streamAudio(
        fileURL: URL, mimeType: String, sessionId: String?, voiceId: String? = nil, tts: String? = nil, harness: String? = nil, mode: String? = nil
    ) -> AsyncThrowingStream<TurnEvent, Error> {
        let boundary = "----HermesVoiceBoundary\(UUID().uuidString)"
        var body = Data()
        let crlf = "\r\n"
        func appendPart(name: String, filename: String? = nil, contentType: String? = nil, data: Data) {
            body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
            var disposition = "Content-Disposition: form-data; name=\"\(name)\""
            if let filename { disposition += "; filename=\"\(filename)\"" }
            body.append("\(disposition)\(crlf)".data(using: .utf8)!)
            if let contentType {
                body.append("Content-Type: \(contentType)\(crlf)".data(using: .utf8)!)
            }
            body.append(crlf.data(using: .utf8)!)
            body.append(data)
            body.append(crlf.data(using: .utf8)!)
        }
        let audio = (try? Data(contentsOf: fileURL)) ?? Data()
        appendPart(name: "file", filename: fileURL.lastPathComponent, contentType: mimeType, data: audio)
        if let sessionId, !sessionId.isEmpty {
            appendPart(name: "session_id", data: sessionId.data(using: .utf8)!)
        }
        if let voiceId, !voiceId.isEmpty {
            appendPart(name: "voice_id", data: voiceId.data(using: .utf8)!)
        }
        if let tts, !tts.isEmpty {
            appendPart(name: "tts", data: tts.data(using: .utf8)!)
        }
        if let harness, !harness.isEmpty {
            appendPart(name: "harness", data: harness.data(using: .utf8)!)
        }
        if let mode, !mode.isEmpty {
            appendPart(name: "mode", data: mode.data(using: .utf8)!)
        }
        body.append("--\(boundary)--\(crlf)".data(using: .utf8)!)
        return events(path: "/api/audio/stream", multipart: (boundary, body))
    }

    private func events(
        path: String,
        jsonBody: [String: Any]? = nil,
        multipart: (boundary: String, body: Data)? = nil
    ) -> AsyncThrowingStream<TurnEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = try buildURL(path)
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.timeoutInterval = 300  // a slow Hermes turn can run a while
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    if !authToken.isEmpty {
                        req.setValue(authToken, forHTTPHeaderField: "X-Hermes-Voice-Token")
                    }
                    if let jsonBody {
                        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        req.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
                    } else if let multipart {
                        req.setValue(
                            "multipart/form-data; boundary=\(multipart.boundary)",
                            forHTTPHeaderField: "Content-Type"
                        )
                        req.httpBody = multipart.body
                    }
                    let (bytes, response) = try await session.bytes(for: req)
                    if let http = response as? HTTPURLResponse,
                       !(200..<300).contains(http.statusCode) {
                        // Non-2xx before any event → the streaming endpoint is
                        // unavailable (e.g. older backend); caller falls back.
                        throw APIError.httpStatus(http.statusCode, "stream unavailable")
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard !payload.isEmpty, let data = payload.data(using: .utf8),
                              let ev = Self.parseEvent(data) else { continue }
                        continuation.yield(ev)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func parseEvent(_ data: Data) -> TurnEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return nil }
        switch type {
        case "transcribed":
            return .transcribed(obj["text"] as? String ?? "")
        case "tool":
            return .tool(
                name: obj["name"] as? String ?? "tool",
                preview: obj["preview"] as? String ?? "",
                ok: obj["ok"] as? Bool ?? true
            )
        case "tools":
            let items = (obj["items"] as? [[String: Any]]) ?? []
            return .tools(items.map {
                ToolCall(
                    name: $0["name"] as? String ?? "tool",
                    preview: $0["preview"] as? String ?? "",
                    ok: $0["ok"] as? Bool ?? true
                )
            })
        case "assistant":
            return .assistant(
                text: obj["text"] as? String ?? "",
                sessionId: obj["session_id"] as? String ?? ""
            )
        case "audio":
            return .audio(path: obj["url"] as? String ?? "")
        case "done":
            return .done(sessionId: obj["session_id"] as? String ?? "")
        case "error":
            return .failed(obj["detail"] as? String ?? "stream error")
        case "turn":
            return .turn(turnId: obj["turn_id"] as? String ?? "")
        case "approval_request":
            return .approvalRequest(
                requestId: obj["request_id"] as? String ?? "",
                tool: obj["tool"] as? String ?? "",
                title: obj["title"] as? String ?? "",
                preview: obj["preview"] as? String ?? ""
            )
        case "question":
            return .question(
                requestId: obj["request_id"] as? String ?? "",
                prompt: obj["prompt"] as? String ?? "",
                options: (obj["options"] as? [String]) ?? [],
                multi: obj["multi"] as? Bool ?? false
            )
        default:
            return nil
        }
    }

    /// Answer a mid-turn approval/question (Phase B). `value` is "allow"/"deny"
    /// for an approval or the selected option(s) for a question.
    func answerTurn(turnId: String, requestId: String, value: Any) async throws {
        let url = try buildURL("/api/turns/\(turnId)/answer")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(
            withJSONObject: ["request_id": requestId, "value": value]
        )
        let (data, response) = try await perform(req)
        try Self.ensureOK(response, data: data)
    }

    /// Build the absolute URL for a backend path. Used by AVPlayer to stream
    /// audio directly from the backend rather than downloading first.
    func makeURL(path: String) -> URL? {
        try? buildURL(path)
    }

    func downloadAudio(path: String) async throws -> URL {
        // path is "/api/audio/<id>" returned by the backend
        let url = try buildURL(path)
        let (data, response) = try await perform(URLRequest(url: url))
        try Self.ensureOK(response, data: data)
        let ext = (url.pathExtension.isEmpty ? "mp3" : url.pathExtension)
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("hv-\(UUID().uuidString).\(ext.isEmpty ? "mp3" : ext)")
        try data.write(to: dest)
        return dest
    }

    // MARK: - Voices

    struct VoiceOption: Decodable, Identifiable, Equatable {
        var id: String { voiceId }
        let voiceId: String
        let name: String
        let category: String?

        enum CodingKeys: String, CodingKey {
            case voiceId = "voice_id"
            case name
            case category
        }
    }

    func listVoices() async throws -> [VoiceOption] {
        let url = try buildURL("/api/voices")
        let (data, response) = try await perform(URLRequest(url: url))
        try Self.ensureOK(response, data: data)
        do {
            return try Self.decoder.decode([VoiceOption].self, from: data)
        } catch {
            throw APIError.decode(error)
        }
    }

    // MARK: - Harnesses

    struct HarnessOption: Decodable, Identifiable, Equatable {
        var id: String { harnessId }
        let harnessId: String
        let name: String
        let available: Bool

        enum CodingKeys: String, CodingKey {
            case harnessId = "id"
            case name
            case available
        }
    }

    func listHarnesses() async throws -> [HarnessOption] {
        let url = try buildURL("/api/harnesses")
        let (data, response) = try await perform(URLRequest(url: url))
        try Self.ensureOK(response, data: data)
        do {
            return try Self.decoder.decode([HarnessOption].self, from: data)
        } catch {
            throw APIError.decode(error)
        }
    }

    /// One existing session a harness can resume — surfaced in the attach picker.
    /// Coding agents fill `cwd`/`title`; Hermes leaves them nil.
    struct HarnessSession: Decodable, Identifiable, Equatable {
        var id: String { sessionId }
        let sessionId: String
        let source: String
        let startedAt: Double
        let messageCount: Int
        let toolCallCount: Int
        let preview: String
        let cwd: String?
        let title: String?

        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case source
            case startedAt = "started_at"
            case messageCount = "message_count"
            case toolCallCount = "tool_call_count"
            case preview, cwd, title
        }

        /// Last path component of `cwd` (e.g. "/Users/me/git/foo" → "foo").
        var repo: String? {
            guard let cwd, !cwd.isEmpty else { return nil }
            return URL(fileURLWithPath: cwd).lastPathComponent
        }

        /// Best single-line label: the agent's title if present, else the prompt.
        var displayLabel: String {
            if let title, !title.isEmpty { return title }
            return preview.isEmpty ? sessionId : preview
        }
    }

    func listHarnessSessions(harnessId: String, limit: Int = 30) async throws -> [HarnessSession] {
        let url = try buildURL("/api/harnesses/\(harnessId)/sessions?limit=\(limit)")
        let (data, response) = try await perform(URLRequest(url: url))
        try Self.ensureOK(response, data: data)
        do {
            return try Self.decoder.decode([HarnessSession].self, from: data)
        } catch {
            throw APIError.decode(error)
        }
    }

    // MARK: - Internals

    private static let decoder: JSONDecoder = JSONDecoder()

    private func buildURL(_ path: String) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(trimmed)\(path)") else { throw APIError.badURL }
        return url
    }

    private func perform(_ request: URLRequest, body: Data? = nil) async throws -> (Data, URLResponse) {
        var req = request
        if !authToken.isEmpty {
            req.setValue(authToken, forHTTPHeaderField: "X-Hermes-Voice-Token")
        }
        do {
            if let body {
                return try await session.upload(for: req, from: body)
            }
            return try await session.data(for: req)
        } catch {
            throw APIError.transport(error)
        }
    }

    private static func ensureOK(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "<no body>"
            throw APIError.httpStatus(http.statusCode, body)
        }
    }
}
