import XCTest
@testable import HermesVoice

@MainActor
final class WatchRelayDecisionTests: XCTestCase {
    private let profileP = UUID()
    private let profileQ = UUID()

    // MARK: - resolveRelaySession (pure decision)

    func testMatchingSessionAndProfileForwardsId() {
        let result = PhoneWatchBridge.resolveRelaySession(
            incoming: "s-1",
            stored: (sessionId: "s-1", profileId: profileP),
            activeProfileId: profileP
        )
        XCTAssertEqual(result, "s-1")
    }

    func testSessionIdMismatchDrops() {
        let result = PhoneWatchBridge.resolveRelaySession(
            incoming: "s-2",
            stored: (sessionId: "s-1", profileId: profileP),
            activeProfileId: profileP
        )
        XCTAssertNil(result)
    }

    func testProfileMismatchDrops() {
        // Same session id, but the active profile is a different laptop.
        let result = PhoneWatchBridge.resolveRelaySession(
            incoming: "s-1",
            stored: (sessionId: "s-1", profileId: profileP),
            activeProfileId: profileQ
        )
        XCTAssertNil(result)
    }

    func testNilMarkerDrops() {
        let result = PhoneWatchBridge.resolveRelaySession(
            incoming: "s-1",
            stored: nil,
            activeProfileId: profileP
        )
        XCTAssertNil(result)
    }

    func testEmptyOrNilIncomingDrops() {
        XCTAssertNil(PhoneWatchBridge.resolveRelaySession(
            incoming: "",
            stored: (sessionId: "s-1", profileId: profileP),
            activeProfileId: profileP
        ))
        XCTAssertNil(PhoneWatchBridge.resolveRelaySession(
            incoming: nil,
            stored: (sessionId: "s-1", profileId: profileP),
            activeProfileId: profileP
        ))
    }

    // MARK: - Marker persistence round-trip through injectable UserDefaults

    func testMarkerPairPersistsAndRestores() {
        let suite = "WatchRelayDecisionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        XCTAssertNil(PhoneWatchBridge.loadRelayMarker(from: defaults))

        PhoneWatchBridge.saveRelayMarker((sessionId: "s-42", profileId: profileP), to: defaults)
        let restored = PhoneWatchBridge.loadRelayMarker(from: defaults)
        XCTAssertEqual(restored?.sessionId, "s-42")
        XCTAssertEqual(restored?.profileId, profileP)

        // Clearing removes both keys → nil round-trip.
        PhoneWatchBridge.saveRelayMarker(nil, to: defaults)
        XCTAssertNil(PhoneWatchBridge.loadRelayMarker(from: defaults))
    }
}
