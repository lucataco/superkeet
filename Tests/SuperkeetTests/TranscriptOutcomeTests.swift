import XCTest
@testable import Superkeet

final class TranscriptOutcomeTests: XCTestCase {
    func testDictationOutcomeReflectsHowTextWasDelivered() {
        XCTAssertEqual(TranscriptOutcome.forDictation(delivery: .copied, isPartial: false), .copied)
        XCTAssertEqual(TranscriptOutcome.forDictation(delivery: .pasted, isPartial: false), .pasted)
        // A failed paste still leaves the text on the clipboard, so say so rather than claiming a paste.
        XCTAssertEqual(TranscriptOutcome.forDictation(delivery: .pasteFailed, isPartial: false), .copied)
    }

    func testPartialTakesAlwaysWarnRegardlessOfDelivery() {
        for delivery in [PasteDelivery.copied, .pasted, .pasteFailed] {
            XCTAssertEqual(TranscriptOutcome.forDictation(delivery: delivery, isPartial: true), .partial)
        }
    }

    func testSuccessesDismissFasterThanProblems() {
        XCTAssertLessThan(TranscriptOutcome.copied.displayDuration, TranscriptOutcome.partial.displayDuration)
        XCTAssertLessThan(TranscriptOutcome.pasted.displayDuration, TranscriptOutcome.failed.displayDuration)
        XCTAssertEqual(TranscriptOutcome.partial.displayDuration, TranscriptOutcome.failed.displayDuration)
    }

    func testCommandsHandOffToTheActionsHUD() {
        XCTAssertFalse(TranscriptOutcome.command.showsInOverlay)
        for outcome in [TranscriptOutcome.copied, .pasted, .done, .partial, .noSpeech, .failed] {
            XCTAssertTrue(outcome.showsInOverlay, "\(outcome) should be shown in the overlay")
        }
    }

    func testEveryOutcomeHasALabelAndSymbol() {
        for outcome in [TranscriptOutcome.copied, .pasted, .done, .partial, .noSpeech, .failed, .command] {
            XCTAssertFalse(outcome.label.isEmpty)
            XCTAssertFalse(outcome.symbolName.isEmpty)
        }
    }

    func testOutcomeEventsAreDistinctEvenWhenOutcomesRepeat() {
        let first = TranscriptOutcomeEvent(.copied)
        let second = TranscriptOutcomeEvent(.copied)
        XCTAssertEqual(first.outcome, second.outcome)
        XCTAssertNotEqual(first, second)
    }

    func testOnlyTheRecordingPhaseCountsAsRecording() {
        XCTAssertTrue(OverlayPhase.recording.isRecording)
        XCTAssertFalse(OverlayPhase.transcribing.isRecording)
        XCTAssertFalse(OverlayPhase.result(.copied).isRecording)
    }
}
