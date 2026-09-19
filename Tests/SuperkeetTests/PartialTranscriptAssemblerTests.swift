import XCTest
@testable import Superkeet

final class PartialTranscriptAssemblerTests: XCTestCase {
    private func volatile(_ text: String, _ start: Double = 0, _ end: Double) -> RecognizedPhrase {
        RecognizedPhrase(text: text, isFinal: false, start: start, end: end)
    }

    private func final(_ text: String, _ start: Double = 0, _ end: Double) -> RecognizedPhrase {
        RecognizedPhrase(text: text, isFinal: true, start: start, end: end)
    }

    /// Mirrors the result sequence SpeechAnalyzer produced for the spoken
    /// command in the design probe: growing volatile text, then one final.
    func testGrowingVolatileResultsThenFinal() {
        var assembler = PartialTranscriptAssembler()
        let steps: [(RecognizedPhrase, String, Bool)] = [
            (volatile("Open", 0, 1.1), "Open", false),
            (volatile("Open the", 0, 1.1), "Open the", false),
            (volatile("Open the Notes", 0, 1.1), "Open the Notes", false),
            (volatile("Open the Notes app and create a new", 0, 2.0), "Open the Notes app and create a new", false),
            (volatile("Open the Notes app and create a new note.", 0, 3.03), "Open the Notes app and create a new note.", false),
            (final("Open the Notes app and create a new note.", 0, 2.28), "Open the Notes app and create a new note.", true)
        ]
        var lastSequence = 0
        for (phrase, expectedText, expectedFinal) in steps {
            let transcript = assembler.apply(phrase)
            XCTAssertEqual(transcript?.text, expectedText)
            XCTAssertEqual(transcript?.isFinal, expectedFinal)
            XCTAssertEqual(transcript?.sequence, lastSequence + 1, "Every emitted transcript increments the sequence.")
            lastSequence += 1
        }
    }

    func testUnchangedVolatileTextIsNotReemitted() {
        var assembler = PartialTranscriptAssembler()
        XCTAssertNotNil(assembler.apply(volatile("Open Notes", 0, 1)))
        XCTAssertNil(assembler.apply(volatile("Open Notes", 0, 1.5)), "Same text, later range: nothing new for a consumer.")
        XCTAssertNil(assembler.apply(volatile("  Open Notes ", 0, 1.6)), "Whitespace-only differences are not changes.")
        XCTAssertEqual(assembler.sequence, 1)
    }

    func testFinalPhrasesAccumulateAndVolatileTailFollows() {
        var assembler = PartialTranscriptAssembler()
        _ = assembler.apply(volatile("Open Notes", 0, 1.2))
        let firstFinal = assembler.apply(final("Open Notes.", 0, 1.3))
        XCTAssertEqual(firstFinal?.text, "Open Notes.")
        XCTAssertEqual(firstFinal?.isFinal, true)

        let tail = assembler.apply(volatile("and create", 1.3, 2.4))
        XCTAssertEqual(tail?.text, "Open Notes. and create")
        XCTAssertEqual(tail?.isFinal, false)

        let secondFinal = assembler.apply(final("and create a note.", 1.3, 2.9))
        XCTAssertEqual(secondFinal?.text, "Open Notes. and create a note.")
        XCTAssertEqual(secondFinal?.isFinal, true)
    }

    func testStaleVolatilePhraseInsideCommittedAudioIsIgnored() {
        var assembler = PartialTranscriptAssembler()
        _ = assembler.apply(final("Open Notes.", 0, 1.3))
        XCTAssertNil(assembler.apply(volatile("Open Note", 0, 1.1)), "A volatile phrase ending before the last final is stale.")
        XCTAssertEqual(assembler.transcript, "Open Notes.")
    }

    func testFinalSupersedesOverlappingVolatileButKeepsLaterOne() {
        var assembler = PartialTranscriptAssembler()
        _ = assembler.apply(volatile("and create a note", 1.3, 2.5))
        let result = assembler.apply(final("Open Notes.", 0, 1.3))
        XCTAssertEqual(result?.text, "Open Notes. and create a note", "A volatile tail starting at the final's end is not superseded.")
        XCTAssertEqual(result?.isFinal, false)

        var overlapping = PartialTranscriptAssembler()
        _ = overlapping.apply(volatile("Open Notes and", 0, 1.8))
        let superseded = overlapping.apply(final("Open Notes.", 0, 1.3))
        XCTAssertEqual(superseded?.text, "Open Notes.")
        XCTAssertEqual(superseded?.isFinal, true)
    }

    func testOutOfOrderFinalIsInsertedByStartTime() {
        var assembler = PartialTranscriptAssembler()
        _ = assembler.apply(final("create a note.", 1.3, 2.9))
        _ = assembler.apply(final("Open Notes.", 0, 1.3))
        XCTAssertEqual(assembler.transcript, "Open Notes. create a note.")
    }

    func testEmptyPhrasesProduceNothing() {
        var assembler = PartialTranscriptAssembler()
        XCTAssertNil(assembler.apply(volatile("", 0, 0.5)))
        XCTAssertNil(assembler.apply(volatile("   ", 0, 0.7)))
        XCTAssertEqual(assembler.transcript, "")
        XCTAssertEqual(assembler.sequence, 0)
    }

    func testResetClearsState() {
        var assembler = PartialTranscriptAssembler()
        _ = assembler.apply(final("Open Notes.", 0, 1.3))
        assembler.reset()
        XCTAssertEqual(assembler.transcript, "")
        XCTAssertEqual(assembler.sequence, 0)
        XCTAssertEqual(assembler.apply(volatile("Hi", 0, 0.4))?.sequence, 1)
    }

    func testAvailabilityMessages() {
        XCTAssertTrue(PartialTranscriptAvailability.available.isAvailable)
        XCTAssertNil(PartialTranscriptAvailability.available.userFacingMessage)
        for unavailable in [PartialTranscriptAvailability.requiresNewerOS, .unsupportedLocale("xx-XX"), .assetsNotInstalled,
                            .assetsDownloading, .unavailable("no model")] {
            XCTAssertFalse(unavailable.isAvailable)
            XCTAssertFalse(unavailable.userFacingMessage?.isEmpty ?? true, "\(unavailable)")
        }
        XCTAssertTrue(PartialTranscriptAvailability.unsupportedLocale("xx-XX").userFacingMessage?.contains("xx-XX") == true)
    }
}
