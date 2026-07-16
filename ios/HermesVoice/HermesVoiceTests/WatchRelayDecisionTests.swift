import XCTest
@testable import HermesVoice

@MainActor
final class WatchRelayDecisionTests: XCTestCase {
    private let profileP = UUID()
    private let profileQ = UUID()

    // MARK: - resolveRelaySession (pure decision)

    func testMatchingSessionProfileAndHarnessForwardsId() {
        let result = PhoneWatchBridge.resolveRelaySession(
            incoming: "s-1",
            stored: (sessionId: "s-1", profileId: profileP, harness: "claude"),
            activeProfileId: profileP,
            activeHarness: "claude"
        )
        XCTAssertEqual(result, "s-1")
    }

    func testSessionIdMismatchDrops() {
        let result = PhoneWatchBridge.resolveRelaySession(
            incoming: "s-2",
            stored: (sessionId: "s-1", profileId: profileP, harness: "claude"),
            activeProfileId: profileP,
            activeHarness: "claude"
        )
        XCTAssertNil(result)
    }

    func testProfileMismatchDrops() {
        // Same session id + harness, but the active profile is a different laptop.
        let result = PhoneWatchBridge.resolveRelaySession(
            incoming: "s-1",
            stored: (sessionId: "s-1", profileId: profileP, harness: "claude"),
            activeProfileId: profileQ,
            activeHarness: "claude"
        )
        XCTAssertNil(result)
    }

    func testHarnessMismatchDrops() {
        // Same session id + profile, but the active harness changed under the
        // same profile UUID (e.g. `attach()` adopted a different harness) — the
        // stored session was created under the OLD harness, so it must drop.
        let result = PhoneWatchBridge.resolveRelaySession(
            incoming: "s-1",
            stored: (sessionId: "s-1", profileId: profileP, harness: "claude"),
            activeProfileId: profileP,
            activeHarness: "codex"
        )
        XCTAssertNil(result)
    }

    func testNilMarkerDrops() {
        let result = PhoneWatchBridge.resolveRelaySession(
            incoming: "s-1",
            stored: nil,
            activeProfileId: profileP,
            activeHarness: "claude"
        )
        XCTAssertNil(result)
    }

    func testEmptyOrNilIncomingDrops() {
        XCTAssertNil(PhoneWatchBridge.resolveRelaySession(
            incoming: "",
            stored: (sessionId: "s-1", profileId: profileP, harness: "claude"),
            activeProfileId: profileP,
            activeHarness: "claude"
        ))
        XCTAssertNil(PhoneWatchBridge.resolveRelaySession(
            incoming: nil,
            stored: (sessionId: "s-1", profileId: profileP, harness: "claude"),
            activeProfileId: profileP,
            activeHarness: "claude"
        ))
    }

    // MARK: - Marker persistence round-trip through injectable UserDefaults

    func testMarkerTriplePersistsAndRestores() {
        let suite = "WatchRelayDecisionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        XCTAssertNil(PhoneWatchBridge.loadRelayMarker(from: defaults))

        PhoneWatchBridge.saveRelayMarker((sessionId: "s-42", profileId: profileP, harness: "claude"), to: defaults)
        let restored = PhoneWatchBridge.loadRelayMarker(from: defaults)
        XCTAssertEqual(restored?.sessionId, "s-42")
        XCTAssertEqual(restored?.profileId, profileP)
        XCTAssertEqual(restored?.harness, "claude")

        // Clearing removes all keys → nil round-trip.
        PhoneWatchBridge.saveRelayMarker(nil, to: defaults)
        XCTAssertNil(PhoneWatchBridge.loadRelayMarker(from: defaults))
    }

    func testMarkerMissingHarnessKeyReadsAsNil() {
        // A pre-upgrade marker written before the harness field existed (only
        // id + profile keys) reads as nil — a one-time safe drop of continuity.
        let suite = "WatchRelayDecisionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set("s-legacy", forKey: "hv.watch.sessionID")
        defaults.set(profileP.uuidString, forKey: "hv.watch.sessionProfileID")

        XCTAssertNil(PhoneWatchBridge.loadRelayMarker(from: defaults))
    }
}
