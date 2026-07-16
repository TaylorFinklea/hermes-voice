import Foundation

/// A saved backend connection: URL + auth token + the harness last used with
/// it. One profile per laptop/server the phone can switch between. Persisted
/// as part of `AppSettings.backendProfiles`.
struct BackendProfile: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var url: String
    var authToken: String
    var selectedHarness: String

    init(id: UUID = UUID(), name: String, url: String, authToken: String, selectedHarness: String) {
        self.id = id
        self.name = name
        self.url = url
        self.authToken = authToken
        self.selectedHarness = selectedHarness
    }

    /// Derives a display name from a URL's host (e.g. "studio.tailnet.ts.net").
    /// Falls back to a generic label when the URL has no parseable host.
    static func suggestedName(for url: String) -> String {
        guard let host = URL(string: url)?.host, !host.isEmpty else {
            return "Hermes server"
        }
        return host
    }
}
