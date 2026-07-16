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

    // MARK: - nextRelayMarker (pure marker-tagging decision)

    func testNextRelayMarkerTagsSnapshotRoute() {
        // The marker MUST carry the snapshot route it was given, not any live
        // value — this is the whole point of tagging from the bound snapshot.
        let marker = PhoneWatchBridge.nextRelayMarker(
            routeProfileId: profileP,
            routeHarness: "claude",
            responseSessionId: "s-1"
        )
        XCTAssertEqual(marker?.sessionId, "s-1")
        XCTAssertEqual(marker?.profileId, profileP)
        XCTAssertEqual(marker?.harness, "claude")
    }

    func testNextRelayMarkerEmptyResponseLeavesMarkerUntouched() {
        // Empty response session id → nil → the caller leaves the stored marker
        // untouched (mirrors WatchSession.handleResponse on an empty response).
        XCTAssertNil(PhoneWatchBridge.nextRelayMarker(
            routeProfileId: profileP,
            routeHarness: "claude",
            responseSessionId: ""
        ))
    }

    // MARK: - Interleaving convergence (nextRelayMarker → resolveRelaySession)

    func testStaleResponseTaggedWithSnapshotIsDroppedUnderNewProfile() {
        // Reproduces the review's relay interleaving at the decision level:
        //  1. A relay starts under profile P / harness "claude"; the snapshot
        //     binds that route. The upload suspends.
        //  2. A switch flips the LIVE route to profile Q / harness "codex" and
        //     clears the marker.
        //  3. The stale response ("s-A") returns. Tagging from the SNAPSHOT (not
        //     live settings) records (s-A, P, claude) — NOT (s-A, Q, codex).
        let stored = PhoneWatchBridge.nextRelayMarker(
            routeProfileId: profileP,          // snapshot route, bound at start
            routeHarness: "claude",
            responseSessionId: "s-A"
        )
        XCTAssertEqual(stored?.profileId, profileP, "must carry snapshot profile, not live Q")
        XCTAssertEqual(stored?.harness, "claude", "must carry snapshot harness, not live codex")

        //  4. The next Watch turn under the NEW route (Q / codex) presents the
        //     Watch's session id "s-A". Because the marker carries the OLD route,
        //     the triple check mismatches and the stale session is DROPPED — A's
        //     session never leaks into the new route.
        let forwarded = PhoneWatchBridge.resolveRelaySession(
            incoming: "s-A",
            stored: stored,
            activeProfileId: profileQ,          // live route after the switch
            activeHarness: "codex"
        )
        XCTAssertNil(forwarded, "stale A session must not forward under the switched route")
    }

    func testStaleResponseTaggedWithSnapshotIsDroppedUnderNewHarnessSameProfile() {
        // Harness-only variant: `attach()` adopts a different harness under the
        // SAME profile UUID. Snapshot tagging records the OLD harness, so the
        // next turn under the new harness still drops the stale session.
        let stored = PhoneWatchBridge.nextRelayMarker(
            routeProfileId: profileP,
            routeHarness: "claude",             // snapshot harness
            responseSessionId: "s-A"
        )
        XCTAssertEqual(stored?.harness, "claude")

        let forwarded = PhoneWatchBridge.resolveRelaySession(
            incoming: "s-A",
            stored: stored,
            activeProfileId: profileP,          // same profile
            activeHarness: "codex"              // harness switched mid-flight
        )
        XCTAssertNil(forwarded, "stale session under the old harness must not forward")
    }

    func testFreshResponseTaggedWithSnapshotForwardsWhenRouteUnchanged() {
        // Control: when NO switch happens, the snapshot equals the live route, so
        // a fresh relay's marker forwards on the next turn (continuity preserved).
        let stored = PhoneWatchBridge.nextRelayMarker(
            routeProfileId: profileP,
            routeHarness: "claude",
            responseSessionId: "s-A"
        )
        let forwarded = PhoneWatchBridge.resolveRelaySession(
            incoming: "s-A",
            stored: stored,
            activeProfileId: profileP,
            activeHarness: "claude"
        )
        XCTAssertEqual(forwarded, "s-A", "unchanged route must preserve Watch continuity")
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
