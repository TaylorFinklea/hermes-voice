import XCTest
@testable import HermesVoice

@MainActor
final class BackendProfileTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        let suite = "BackendProfileTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    func testMigratesLegacyBackendIntoActiveProfile() {
        defaults.set("https://studio.tailnet.ts.net:8765", forKey: "hv.backendURL")
        defaults.set("token-a", forKey: "hv.authToken")
        defaults.set("claude", forKey: "hv.selectedHarness")

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.backendProfiles.count, 1)
        XCTAssertEqual(settings.backendURL, "https://studio.tailnet.ts.net:8765")
        XCTAssertEqual(settings.authToken, "token-a")
        XCTAssertEqual(settings.selectedHarness, "claude")
        XCTAssertEqual(settings.activeBackendProfile.name, "studio.tailnet.ts.net")
    }

    func testActivatingProfileRestoresItsHarness() {
        let settings = AppSettings(defaults: defaults)
        let first = settings.activeBackendProfile
        settings.selectedHarness = "claude"
        let second = BackendProfile(name: "Laptop", url: "https://laptop.example:8765", authToken: "b", selectedHarness: "codex")
        settings.saveProfile(second)

        XCTAssertTrue(settings.activateProfile(id: second.id))
        XCTAssertEqual(settings.selectedHarness, "codex")
        XCTAssertTrue(settings.activateProfile(id: first.id))
        XCTAssertEqual(settings.selectedHarness, "claude")
    }

    func testCannotDeleteActiveOrOnlyProfile() {
        let settings = AppSettings(defaults: defaults)
        let only = settings.activeBackendProfile
        XCTAssertFalse(settings.removeProfile(id: only.id))

        let other = BackendProfile(name: "Other", url: "https://other.example:8765", authToken: "", selectedHarness: "hermes")
        settings.saveProfile(other)
        XCTAssertFalse(settings.removeProfile(id: only.id))
        XCTAssertTrue(settings.removeProfile(id: other.id))
    }

    func testCorruptProfilesPayloadFallsBackToMigrationPath() {
        let garbage = Data([0x00, 0xFF, 0x10, 0x22, 0x7B])
        defaults.set(garbage, forKey: "hv.backendProfiles")

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.backendProfiles.count, 1)
        XCTAssertEqual(settings.backendURL, "http://127.0.0.1:8765")

        settings.saveProfile(
            BackendProfile(name: "Laptop", url: "https://laptop.example:8765", authToken: "x", selectedHarness: "codex")
        )

        let saved = defaults.data(forKey: "hv.backendProfiles")
        XCTAssertNotNil(saved)
        let decoded = try? JSONDecoder().decode([BackendProfile].self, from: saved!)
        XCTAssertEqual(decoded?.count, 2)
    }

    func testActivateProfileWithUnknownIdIsNoOp() {
        // Seed legacy keys so they're actually persisted (a truly fresh
        // suite never writes `hv.backendURL` et al. until something mutates
        // the active profile), giving a real baseline to compare against.
        defaults.set("https://studio.tailnet.ts.net:8765", forKey: "hv.backendURL")
        defaults.set("token-a", forKey: "hv.authToken")
        defaults.set("claude", forKey: "hv.selectedHarness")

        let settings = AppSettings(defaults: defaults)
        let originalActiveId = settings.activeProfileId
        let originalURL = settings.backendURL
        let originalToken = settings.authToken
        let originalHarness = settings.selectedHarness

        XCTAssertFalse(settings.activateProfile(id: UUID()))

        XCTAssertEqual(settings.activeProfileId, originalActiveId)
        XCTAssertEqual(settings.backendURL, originalURL)
        XCTAssertEqual(settings.authToken, originalToken)
        XCTAssertEqual(settings.selectedHarness, originalHarness)
        XCTAssertEqual(defaults.string(forKey: "hv.backendURL"), originalURL)
        XCTAssertEqual(defaults.string(forKey: "hv.authToken"), originalToken)
        XCTAssertEqual(defaults.string(forKey: "hv.selectedHarness"), originalHarness)
    }

    func testSuggestedNameFallsBackForUnparseableOrEmptyHostURL() {
        XCTAssertEqual(BackendProfile.suggestedName(for: ""), "Hermes server")
        XCTAssertEqual(BackendProfile.suggestedName(for: "not a valid url"), "Hermes server")
        XCTAssertEqual(BackendProfile.suggestedName(for: "https://"), "Hermes server")
    }

    func testSecondProfileSurvivesReconstruction() {
        let settings = AppSettings(defaults: defaults)
        let second = BackendProfile(name: "Laptop", url: "https://laptop.example:8765", authToken: "tok-b", selectedHarness: "codex")
        settings.saveProfile(second)
        XCTAssertTrue(settings.activateProfile(id: second.id))

        let reconstructed = AppSettings(defaults: defaults)

        XCTAssertEqual(reconstructed.activeProfileId, second.id)
        XCTAssertEqual(reconstructed.backendURL, second.url)
        XCTAssertEqual(reconstructed.authToken, second.authToken)
        XCTAssertEqual(reconstructed.selectedHarness, second.selectedHarness)
    }

    func testRepairsBogusActiveProfileId() {
        let profile = BackendProfile(name: "Laptop", url: "https://laptop.example:8765", authToken: "tok", selectedHarness: "codex")
        let data = try! JSONEncoder().encode([profile])
        defaults.set(data, forKey: "hv.backendProfiles")
        defaults.set(UUID().uuidString, forKey: "hv.activeBackendProfileId")

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.activeProfileId, profile.id)
        XCTAssertEqual(defaults.string(forKey: "hv.activeBackendProfileId"), profile.id.uuidString)
        XCTAssertEqual(defaults.string(forKey: "hv.backendURL"), profile.url)
        XCTAssertEqual(defaults.string(forKey: "hv.authToken"), profile.authToken)
        XCTAssertEqual(defaults.string(forKey: "hv.selectedHarness"), profile.selectedHarness)
    }

    func testOnboardingCompletedInferredFromActiveProfileURL() {
        // Legacy key still holds the loopback default, but the decoded
        // active profile has a real URL — onboarding must be considered
        // complete based on the profile, not the stale legacy key.
        defaults.set("http://127.0.0.1:8765", forKey: "hv.backendURL")
        let profile = BackendProfile(name: "Laptop", url: "https://laptop.example:8765", authToken: "tok", selectedHarness: "hermes")
        let data = try! JSONEncoder().encode([profile])
        defaults.set(data, forKey: "hv.backendProfiles")
        defaults.set(profile.id.uuidString, forKey: "hv.activeBackendProfileId")

        let settings = AppSettings(defaults: defaults)

        XCTAssertTrue(settings.hasCompletedOnboarding)
    }

    func testActivatingProfileClearsLastReachable() {
        let settings = AppSettings(defaults: defaults)
        settings.markReachable()
        XCTAssertNotNil(settings.lastReachable)

        let second = BackendProfile(name: "Laptop", url: "https://laptop.example:8765", authToken: "b", selectedHarness: "codex")
        settings.saveProfile(second)
        XCTAssertTrue(settings.activateProfile(id: second.id))

        XCTAssertNil(settings.lastReachable)
    }
}
