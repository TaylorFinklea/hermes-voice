import XCTest
@testable import HermesVoice

/// Table-driven coverage for the static voice-answer parsers on
/// `ConversationViewModel` (ViewModels/ConversationViewModel.swift):
/// `parseYesNo` (approve/deny with deny-wins precedence) and `parseSelection`
/// (label substring → ordinal fallback, multi- vs single-select). These are
/// pure static functions but the type is `@MainActor`, so the suite is too.
@MainActor
final class AnswerParsingTests: XCTestCase {

    // MARK: parseYesNo

    func testParseYesNoTable() {
        let cases: [(input: String, expected: Bool?)] = [
            ("yes", true),
            ("yeah go ahead", true),
            ("sure", true),
            ("approve", true),
            ("ok.", true),
            ("affirmative", true),
            ("no", false),
            ("nope", false),
            ("deny", false),
            ("cancel that", false),
            ("don't", false),
            ("do not do that", false),
            // No yes/no keyword at all → unclear.
            ("maybe later", nil),
            ("the weather is fine", nil),
            ("", nil),
        ]
        for c in cases {
            XCTAssertEqual(
                ConversationViewModel.parseYesNo(c.input), c.expected,
                "parseYesNo(\(c.input.debugDescription)) mismatch"
            )
        }
    }

    /// A "no" word must beat a "yes" word — deny is the safer default.
    func testParseYesNoDenyPrecedence() {
        XCTAssertEqual(ConversationViewModel.parseYesNo("yes no"), false)
        XCTAssertEqual(ConversationViewModel.parseYesNo("approve but cancel"), false)
        XCTAssertEqual(ConversationViewModel.parseYesNo("ok skip it"), false)
    }

    // MARK: parseSelection — label matching

    func testSelectionLabelSubstringSingle() {
        let options = ["Apple", "Banana", "Cherry"]
        XCTAssertEqual(
            ConversationViewModel.parseSelection("I'll take the banana", options: options, multi: false),
            ["Banana"]
        )
    }

    /// Multi-select keeps every matched label; single-select takes the first.
    func testSelectionMultiVsSingle() {
        let options = ["Red", "Green", "Blue"]
        XCTAssertEqual(
            ConversationViewModel.parseSelection("red and blue please", options: options, multi: true),
            ["Red", "Blue"]
        )
        XCTAssertEqual(
            ConversationViewModel.parseSelection("red and blue please", options: options, multi: false),
            ["Red"]
        )
    }

    // MARK: parseSelection — ordinal fallback

    func testSelectionOrdinalWords() {
        let options = ["Alpha", "Beta", "Gamma"]
        XCTAssertEqual(
            ConversationViewModel.parseSelection("the first one", options: options, multi: false),
            ["Alpha"]
        )
        XCTAssertEqual(
            ConversationViewModel.parseSelection("second", options: options, multi: false),
            ["Beta"]
        )
        XCTAssertEqual(
            ConversationViewModel.parseSelection("option three", options: options, multi: false),
            ["Gamma"]
        )
    }

    func testSelectionOrdinalDigits() {
        let options = ["One", "Two", "Three", "Four"]
        XCTAssertEqual(
            ConversationViewModel.parseSelection("number 4", options: options, multi: false),
            ["Four"]
        )
    }

    /// Ordinal fallback only fires when no label matched; an in-range ordinal
    /// beyond the option count yields nil.
    func testSelectionNoMatchReturnsNil() {
        let options = ["Alpha", "Beta"]
        XCTAssertNil(
            ConversationViewModel.parseSelection("nothing relevant here", options: options, multi: false)
        )
        // "fifth" → index 4, out of range for a 2-option list.
        XCTAssertNil(
            ConversationViewModel.parseSelection("fifth", options: options, multi: false)
        )
    }

    /// Empty option labels are never matched as substrings.
    func testSelectionIgnoresEmptyOptions() {
        let options = ["", "Real"]
        XCTAssertEqual(
            ConversationViewModel.parseSelection("real choice", options: options, multi: true),
            ["Real"]
        )
    }
}
