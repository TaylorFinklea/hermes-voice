import Foundation
import Combine
import FluidAudio

/// On-device Voice Activity Detection (Silero v6 via FluidAudio's `VadManager`),
/// used by hands-free conversation mode to know when the user has finished
/// speaking. Mirrors `LocalTranscriber`/`LocalSpeaker`: the model is a separate
/// (small) CoreML download, gated behind an explicit Settings download + warmed
/// at launch — never lazy-fetched the moment you start a conversation.
///
/// `@MainActor` so `@Published state` drives the Settings row and the cached
/// manager is accessed serially.
@MainActor
final class LocalVad: ObservableObject {
    static let shared = LocalVad()

    enum ModelState: Equatable {
        case notDownloaded
        case downloading
        case ready
        case failed(String)
    }

    @Published private(set) var state: ModelState = .notDownloaded

    var isReady: Bool { state == .ready }

    private var manager: VadManager?
    private var loadTask: Task<VadManager, Error>?

    private init() {
        if UserDefaults.standard.bool(forKey: Self.downloadedKey) {
            state = .ready
        }
    }

    func prepare() async {
        if case .downloading = state { return }
        state = .downloading
        do {
            _ = try await ensureManager()
            UserDefaults.standard.set(true, forKey: Self.downloadedKey)
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func warmUpIfDownloaded() {
        guard isReady, manager == nil, loadTask == nil else { return }
        Task { [weak self] in _ = try? await self?.ensureManager() }
    }

    /// The warm `VadManager` actor — the capture engine owns the per-session
    /// `VadStreamState`; this just hands back the loaded model.
    func ensureManager() async throws -> VadManager {
        if let manager { return manager }
        if let loadTask { return try await loadTask.value }
        // `VadManager.init` downloads (if missing) + loads the Silero model.
        let task = Task { () throws -> VadManager in
            try await VadManager(config: .default)
        }
        loadTask = task
        do {
            let m = try await task.value
            manager = m
            loadTask = nil
            return m
        } catch {
            loadTask = nil
            throw error
        }
    }

    private static let downloadedKey = "hv.vadDownloaded"
}
