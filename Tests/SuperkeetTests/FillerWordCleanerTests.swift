import XCTest
@testable import Superkeet

final class FillerWordCleanerTests: XCTestCase {
    func testTextWithNoFillerWords() {
        let input = "The quick brown fox jumps over the lazy dog"
        XCTAssertEqual(FillerWordCleaner.clean(input), input)
    }

    func testRemovesSingleFillerWord() {
        XCTAssertEqual(FillerWordCleaner.clean("I uh think so"), "I think so")
    }

    func testRemovesMultipleFillerWords() {
        XCTAssertEqual(
            FillerWordCleaner.clean("So um I was uh thinking about er that"),
            "So I was thinking about that"
        )
    }

    func testTextThatIsEntirelyFillerWords() {
        XCTAssertEqual(FillerWordCleaner.clean("uh um er hmm"), "")
    }

    func testCaseInsensitivity() {
        XCTAssertEqual(FillerWordCleaner.clean("Um I think Uh yes"), "I think yes")
    }

    func testFillerWordWithTrailingComma() {
        XCTAssertEqual(
            FillerWordCleaner.clean("Well, um, I think so"),
            "Well, I think so"
        )
    }

    func testFillerWordAtStartOfSentence() {
        XCTAssertEqual(FillerWordCleaner.clean("Uh hello there"), "hello there")
    }

    func testFillerWordAtEndOfSentence() {
        XCTAssertEqual(FillerWordCleaner.clean("that was great uh"), "that was great")
    }

    func testDoubleSpaceCleanup() {
        // After removing a filler word from the middle, double spaces should collapse
        let result = FillerWordCleaner.clean("I  um  think")
        XCTAssertFalse(result.contains("  "), "Result should not contain double spaces")
    }

    func testEmptyStringInput() {
        XCTAssertEqual(FillerWordCleaner.clean(""), "")
    }

    func testAllFillerVariants() {
        // Test each recognized filler word individually
        let fillers = ["uh", "uhh", "um", "umm", "er", "err", "hmm", "hmmm", "ah", "ahh", "ugh"]
        for filler in fillers {
            let result = FillerWordCleaner.clean("yes \(filler) okay")
            XCTAssertEqual(result, "yes okay", "Failed to remove filler: \(filler)")
        }
    }

    func testDoesNotRemovePartialMatches() {
        // "umbrella" contains "um" but should not be altered
        XCTAssertEqual(FillerWordCleaner.clean("grab the umbrella"), "grab the umbrella")
    }
}
