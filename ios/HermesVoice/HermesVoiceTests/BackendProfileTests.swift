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
}
