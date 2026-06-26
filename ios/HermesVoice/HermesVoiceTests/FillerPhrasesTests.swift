import XCTest
@testable import HermesVoice

/// `FillerPhrases.ack()` returns warm, casual acknowledgments and must never
/// repeat the same phrase twice in a row (so the instant ack doesn't sound
/// stuck on one line across rapid turns).
final class FillerPhrasesTests: XCTestCase {
    func testAckNeverRepeatsConsecutively() {
        var previous = FillerPhrases.ack()
        for _ in 0..<1000 {
            let next = FillerPhrases.ack()
            XCTAssertNotEqual(next, previous, "ack() returned the same phrase twice in a row")
            previous = next
        }
    }

    func testAckIsNonEmpty() {
        for _ in 0..<100 {
            XCTAssertFalse(
                FillerPhrases.ack().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "ack() returned an empty phrase"
            )
        }
    }
}
