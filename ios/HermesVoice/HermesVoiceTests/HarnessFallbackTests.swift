import XCTest
@testable import HermesVoice

final class HarnessFallbackTests: XCTestCase {
    private func option(_ id: String, available: Bool) -> HermesVoiceAPI.HarnessOption {
        HermesVoiceAPI.HarnessOption(harnessId: id, name: id.capitalized, available: available)
    }

    func testAvailableStoredHarnessKeepsCurrent() {
        let outcome = SettingsView.resolveHarnessFallback(
            stored: "claude",
            available: [option("claude", available: true), option("codex", available: true)],
            gateEligible: true
        )
        XCTAssertEqual(outcome, .keepCurrent)
    }

    func testMissingHarnessWhenEligibleFallsBackToFirstAvailable() {
        let outcome = SettingsView.resolveHarnessFallback(
            stored: "claude",   // no longer offered
            available: [option("codex", available: true), option("opencode", available: true)],
            gateEligible: true
        )
        XCTAssertEqual(outcome, .applyFallback("codex"))
    }

    func testFallbackSkipsUnavailableEntriesForFirstAvailable() {
        let outcome = SettingsView.resolveHarnessFallback(
            stored: "claude",
            available: [option("codex", available: false), option("opencode", available: true)],
            gateEligible: true
        )
        XCTAssertEqual(outcome, .applyFallback("opencode"))
    }

    func testStoredHarnessPresentButUnavailableFallsBack() {
        // Offered but not runnable (CLI uninstalled) still counts as "missing".
        let outcome = SettingsView.resolveHarnessFallback(
            stored: "claude",
            available: [option("claude", available: false), option("codex", available: true)],
            gateEligible: true
        )
        XCTAssertEqual(outcome, .applyFallback("codex"))
    }

    func testMissingHarnessWhenBlockedDefers() {
        let outcome = SettingsView.resolveHarnessFallback(
            stored: "claude",
            available: [option("codex", available: true)],
            gateEligible: false   // live turn / hands-free / Watch relay in flight
        )
        XCTAssertEqual(outcome, .deferApply)
    }

    func testEmptyListDefersAndNeverApplies() {
        let outcome = SettingsView.resolveHarnessFallback(
            stored: "claude",
            available: [],
            gateEligible: true
        )
        XCTAssertEqual(outcome, .deferApply)
    }
}
