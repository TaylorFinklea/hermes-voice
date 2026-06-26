import XCTest
@testable import HermesVoice

/// `FillerVerbosity` gates the spoken-filler behavior. The ordering
/// (off < quiet < normal < chatty) drives the `!= .off` and `>= .normal` gates,
/// and the raw value backs UserDefaults persistence — both must hold.
final class FillerVerbosityTests: XCTestCase {
    func testComparableOrdering() {
        XCTAssertTrue(FillerVerbosity.off < .quiet)
        XCTAssertTrue(FillerVerbosity.quiet < .normal)
        XCTAssertTrue(FillerVerbosity.normal < .chatty)

        // Transitivity / full order.
        let sorted = FillerVerbosity.allCases.shuffled().sorted()
        XCTAssertEqual(sorted, [.off, .quiet, .normal, .chatty])

        // The gates the VM relies on.
        XCTAssertTrue(FillerVerbosity.off == .off)
        XCTAssertTrue(FillerVerbosity.quiet != .off)
        XCTAssertFalse(FillerVerbosity.quiet >= .normal)
        XCTAssertTrue(FillerVerbosity.normal >= .normal)
        XCTAssertTrue(FillerVerbosity.chatty >= .normal)
    }

    func testRawValueRoundTrip() {
        for v in FillerVerbosity.allCases {
            let restored = FillerVerbosity(rawValue: v.rawValue)
            XCTAssertEqual(restored, v, "round-trip failed for \(v)")
        }
    }

    func testUnknownRawValueIsNil() {
        XCTAssertNil(FillerVerbosity(rawValue: "loud"))
        XCTAssertNil(FillerVerbosity(rawValue: ""))
    }

    func testEveryCaseHasANonEmptyLabel() {
        for v in FillerVerbosity.allCases {
            XCTAssertFalse(v.label.isEmpty, "missing label for \(v)")
        }
    }
}
