import XCTest
@testable import HermesVoice

/// Machine-verifies that the on-device Swift `LocalSpeaker.makeSpeakable` stays
/// in lockstep with the backend Python `make_speakable`. Both run the SAME
/// shared corpus — `backend/tests/fixtures/speakable_cases.json`, also driven by
/// `backend/tests/test_speakable.py` — so a divergence in either implementation
/// fails a test instead of silently shipping mismatched spoken output.
@MainActor
final class LocalSpeakerSpeakableTests: XCTestCase {
    private struct SpeakableCase: Decodable {
        let name: String
        let input: String
        let expected: String
    }

    private func loadCases() throws -> [SpeakableCase] {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "speakable_cases", withExtension: "json"),
            "speakable_cases.json was not bundled into the test target"
        )
        return try JSONDecoder().decode([SpeakableCase].self, from: Data(contentsOf: url))
    }

    func testMatchesSharedCorpus() throws {
        let cases = try loadCases()
        XCTAssertFalse(cases.isEmpty, "shared corpus is empty")
        for c in cases {
            XCTAssertEqual(
                LocalSpeaker.makeSpeakable(c.input), c.expected,
                "makeSpeakable diverged from the backend on case '\(c.name)'"
            )
        }
    }

    func testIsIdempotent() throws {
        for c in try loadCases() {
            let once = LocalSpeaker.makeSpeakable(c.input)
            XCTAssertEqual(
                LocalSpeaker.makeSpeakable(once), once,
                "makeSpeakable not idempotent on case '\(c.name)'"
            )
        }
    }
}
