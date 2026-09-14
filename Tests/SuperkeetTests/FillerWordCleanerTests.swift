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
            "So I was thinking about er that"
        )
    }

    func testTextThatIsEntirelyFillerWords() {
        XCTAssertEqual(FillerWordCleaner.clean("uh um uhh umm"), "")
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
        let result = FillerWordCleaner.clean("I  um  think")
        XCTAssertFalse(result.contains("  "), "Result should not contain double spaces")
    }

    func testEmptyStringInput() {
        XCTAssertEqual(FillerWordCleaner.clean(""), "")
    }

    func testAllFillerVariants() {
        let fillers = ["uh", "uhh", "um", "umm"]
        for filler in fillers {
            let result = FillerWordCleaner.clean("yes \(filler) okay")
            XCTAssertEqual(result, "yes okay", "Failed to remove filler: \(filler)")
        }
    }

    func testUghIsPreserved() {
        XCTAssertEqual(FillerWordCleaner.clean("ugh this is broken"), "ugh this is broken")
    }

    func testMeaningAndCorrectionMarkersArePreserved() {
        for text in ["Send him to the ER", "orange, err, yellow", "er, no", "hmm, ah, I like that", "A A agreed agreed", "do not turn it off", "orange or yellow"] {
            XCTAssertEqual(FillerWordCleaner.clean(text), text)
        }
    }

    func testFillerRemovalPreservesLineBreaks() {
        XCTAssertEqual(FillerWordCleaner.clean("first um\nsecond"), "first \nsecond")
    }

    func testDoesNotRemovePartialMatches() {
        XCTAssertEqual(FillerWordCleaner.clean("grab the umbrella"), "grab the umbrella")
    }
}
