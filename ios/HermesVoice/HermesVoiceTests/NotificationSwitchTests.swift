import XCTest
@testable import HermesVoice

/// Records the ordered register / unregister calls the switch/registration
/// flows make (url + token), and lets a test gate each call on a continuation
/// so the manager's async orchestration can be driven deterministically:
/// `waitForEventCount` blocks until N calls have arrived; `parkPolicy` suspends
/// a chosen call until `release` resumes it. Monotonic event counts (never a
/// fixed job order) are the only synchronization the assertions depend on.
@MainActor
final class RegistrarHub {
    enum Kind: Equatable { case register, unregister }
    struct Event: Equatable {
        let kind: Kind
        let url: String
        let token: String
    }

    private(set) var events: [Event] = []

    /// Return true to SUSPEND this call until `release(index:)` resumes it.
    var parkPolicy: (Event) -> Bool = { _ in false }
    /// Return a non-nil error to make this call throw (after being recorded),
    /// modeling a backend rejection / network failure.
    var errorPolicy: (Event) -> Error? = { _ in nil }

    private var parked: [Int: CheckedContinuation<Void, Error>] = [:]
    private var countWaiters: [(threshold: Int, cont: CheckedContinuation<Void, Never>)] = []

    func record(_ event: Event) async throws {
        let index = events.count
        events.append(event)
        countWaiters = countWaiters.filter { waiter in
            if events.count >= waiter.threshold {
                waiter.cont.resume()
                return false
            }
            return true
        }
        if parkPolicy(event) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                parked[index] = cont
            }
        }
        if let error = errorPolicy(event) { throw error }
    }

    /// Suspend until at least `n` calls have been recorded.
    func waitForEventCount(_ n: Int) async {
        if events.count >= n { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            countWaiters.append((threshold: n, cont: cont))
        }
    }

    /// Resume a parked call (0-based in arrival order).
    func release(index: Int, throwing error: Error? = nil) {
        guard let cont = parked.removeValue(forKey: index) else { return }
        if let error { cont.resume(throwing: error) } else { cont.resume() }
    }
}

/// Stand-in for `HermesVoiceAPI` on the device register/unregister paths. Every
/// instance the factory hands the manager shares one `hub`, so the ordered log
/// spans all per-backend clients a switch constructs.
private struct FakeDeviceRegistrar: DeviceRegistering {
    let url: String
    let hub: RegistrarHub

    func registerDevice(
        token: String, platform: String, bundleId: String, environment: String
    ) async throws -> HermesVoiceAPI.DeviceResponse {
        try await hub.record(.init(kind: .register, url: url, token: token))
        return HermesVoiceAPI.DeviceResponse(
            token: token, platform: platform, bundleId: bundleId,
            environment: environment, registeredAt: 0, lastSeenAt: 0
        )
    }

    func unregisterDevice(token: String) async throws {
        try await hub.record(.init(kind: .unregister, url: url, token: token))
    }
}

private struct FakeRegistrarError: Error {}

@MainActor
final class NotificationSwitchTests: XCTestCase {
    private var defaults: UserDefaults!
    private var settings: AppSettings!
    private var hub: RegistrarHub!

    private let urlA = "https://a.example:8765"
    private let urlB = "https://b.example:8765"

    override func setUp() {
        super.setUp()
        let suite = "NotificationSwitchTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        settings = AppSettings(defaults: defaults)
        settings.notificationsEnabled = true
        hub = RegistrarHub()
    }

    private func makeManager() -> NotificationManager {
        let hub = hub!
        let manager = NotificationManager(makeRegistrar: { url, _ in
            FakeDeviceRegistrar(url: url, hub: hub)
        })
        manager.configure(settings: settings)
        return manager
    }

    /// Bounded settle used ONLY before a negative assertion (proving NO further
    /// call happens); the deterministic paths gate on `waitForEventCount`.
    private func settleBriefly() async {
        try? await Task.sleep(nanoseconds: 40_000_000)
    }

    // MARK: - Happy path: wait out in-flight, DELETE previous (recorded token), register new

    func testBackendSwitchUnregistersPreviousThenRegistersNewInOrder() async {
        settings.backendURL = urlA
        settings.authToken = "tok-a"
        let manager = makeManager()
        let previous = settings.activeBackendProfile   // url == urlA

        // Register the previous backend; drains fully (record[urlA] = "t1").
        manager.handleAPNsToken(hex: "t1")
        await hub.waitForEventCount(1)

        // Active flips to B, then the switch fires.
        settings.backendURL = urlB
        settings.authToken = "tok-b"
        manager.handleBackendSwitch(previous: previous)
        await hub.waitForEventCount(3)

        XCTAssertEqual(hub.events, [
            .init(kind: .register, url: urlA, token: "t1"),      // initial registration
            .init(kind: .unregister, url: urlA, token: "t1"),    // DELETE previous with its recorded token
            .init(kind: .register, url: urlB, token: "t1"),      // register the new active backend
        ])
    }

    // MARK: - Token-rotation coalescing while a POST is in flight

    func testRotationDuringInFlightCoalescesToSingleReRegisterOnSameTarget() async {
        settings.backendURL = urlA
        settings.authToken = "tok-a"
        // Hold the first POST (t1) in flight so t2 arrives mid-registration.
        hub.parkPolicy = { $0.kind == .register && $0.token == "t1" }
        let manager = makeManager()

        manager.handleAPNsToken(hex: "t1")
        await hub.waitForEventCount(1)          // POST(t1) is parked in flight

        manager.handleAPNsToken(hex: "t2")      // rotation: cached, not yet posted (in-flight guard)
        hub.release(index: 0)                   // POST(t1) completes → coalescing kicks in
        await hub.waitForEventCount(2)

        XCTAssertEqual(hub.events, [
            .init(kind: .register, url: urlA, token: "t1"),
            .init(kind: .register, url: urlA, token: "t2"),   // exactly one trailing re-register, SAME target
        ])
        await settleBriefly()
        XCTAssertEqual(hub.events.count, 2, "coalescing must collapse the burst to one trailing re-register")
    }

    func testRotationSkipsTrailingReRegisterWhenTargetNoLongerActive() async {
        settings.backendURL = urlA
        settings.authToken = "tok-a"
        hub.parkPolicy = { $0.kind == .register && $0.token == "t1" }
        let manager = makeManager()

        manager.handleAPNsToken(hex: "t1")
        await hub.waitForEventCount(1)          // POST(t1) to A parked in flight

        settings.backendURL = urlB              // active moved away from A
        manager.handleAPNsToken(hex: "t2")      // rotation cached
        hub.release(index: 0)                   // POST(t1) completes; target A is no longer active

        await settleBriefly()
        XCTAssertEqual(hub.events, [
            .init(kind: .register, url: urlA, token: "t1"),
        ], "no trailing re-register when the coalescing target is no longer the active backend")
    }

    // MARK: - CAS record removal: a delayed DELETE must not erase a newer record

    func testDelayedDeleteDoesNotEraseNewerRegistrationRecord() async {
        settings.backendURL = urlA
        settings.authToken = "tok-a"
        let profileA = settings.activeBackendProfile   // url == urlA
        // Hold ONLY the first DELETE (token t1) in flight.
        hub.parkPolicy = { $0.kind == .unregister && $0.token == "t1" }
        let manager = makeManager()

        // record[A] = t1
        manager.handleAPNsToken(hex: "t1")
        await hub.waitForEventCount(1)

        // Switch A → B: DELETE(A, t1) starts and parks.
        settings.backendURL = urlB
        settings.authToken = "tok-b"
        manager.handleBackendSwitch(previous: profileA)
        await hub.waitForEventCount(2)

        // While the DELETE is in flight, re-register A with a NEWER token t2.
        settings.backendURL = urlA
        settings.authToken = "tok-a"
        manager.handleAPNsToken(hex: "t2")     // record[A] = t2
        await hub.waitForEventCount(3)

        // Move active away from A and rotate the received token so a wrongly
        // erased record would fall back to t3 (distinct from the record's t2).
        settings.backendURL = urlB
        settings.authToken = "tok-b"
        settings.lastApnsToken = "t3"

        // The delayed DELETE(A, t1) finally lands — CAS must keep record[A] = t2.
        hub.release(index: 1)
        await hub.waitForEventCount(4)          // switch tail re-registers active B with t3

        // Proof: a subsequent switch-away from A unregisters the NEWER token t2,
        // not the fallback t3 — the delayed DELETE did not erase the record.
        manager.handleBackendSwitch(previous: profileA)
        await hub.waitForEventCount(5)

        XCTAssertEqual(hub.events[4], .init(kind: .unregister, url: urlA, token: "t2"),
                       "delayed DELETE must not erase the newer record; switch-away deletes t2, not the fallback t3")
    }

    // MARK: - Registration failure keeps the token cached for a later retry

    func testFailedRegistrationKeepsTokenCachedForNextAttempt() async {
        settings.backendURL = urlA
        settings.authToken = "tok-a"
        var failNextRegister = true
        hub.errorPolicy = { event in
            if event.kind == .register && failNextRegister {
                failNextRegister = false
                return FakeRegistrarError()
            }
            return nil
        }
        let manager = makeManager()

        manager.handleAPNsToken(hex: "t1")     // caches at receipt, then POST fails
        await hub.waitForEventCount(1)

        // Token cached on-receipt despite the failed registration.
        XCTAssertEqual(settings.lastApnsToken, "t1")

        // The next re-register (e.g. a profile switch or Settings load) can post
        // the cached token successfully.
        manager.registerSavedDeviceWithActiveBackendIfNeeded()
        await hub.waitForEventCount(2)

        XCTAssertEqual(hub.events, [
            .init(kind: .register, url: urlA, token: "t1"),   // failed attempt
            .init(kind: .register, url: urlA, token: "t1"),   // successful retry with the cached token
        ])
        XCTAssertEqual(settings.lastApnsToken, "t1")
    }
}
