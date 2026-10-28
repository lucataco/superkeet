import XCTest
@testable import Superkeet

final class TakeCompletionNoticeTests: XCTestCase {
    private func cleaned(_ raw: String) -> String {
        TranscriptTextProcessor.process(
            raw, removeFillers: true, replacements: [], bundleID: "", spokenCommands: false
        )
    }

    func testPartialTakeWithTextSaysPartOfItCouldNotBeTranscribed() {
        let notice = TakeCompletionNotice.resolve(isPartial: true, processedText: cleaned("Send the report"))
        XCTAssertEqual(notice.statusText, "Part of the recording couldn't be transcribed.")
        XCTAssertEqual(notice.settingsDetail, "Part of the recording couldn't be transcribed.")
    }

    func testPartialTakeThatCleansToNothingReadsLikeTheOverlay() {
        let notice = TakeCompletionNotice.resolve(isPartial: true, processedText: cleaned("Um, uh"))
        XCTAssertEqual(notice.statusText, "No speech detected")
        XCTAssertEqual(notice.statusText, TranscriptOutcome.noSpeech.label)
        XCTAssertNil(notice.settingsDetail)
    }

    func testCompleteTakeReadsAsComplete() {
        let notice = TakeCompletionNotice.resolve(isPartial: false, processedText: cleaned("Send the report"))
        XCTAssertEqual(notice.statusText, "Transcription complete")
        XCTAssertNil(notice.settingsDetail)
    }

    func testCompleteTakeThatCleansToNothingReadsLikeTheOverlay() {
        let notice = TakeCompletionNotice.resolve(isPartial: false, processedText: cleaned("Um, uh"))
        XCTAssertEqual(notice.statusText, "No speech detected")
        XCTAssertEqual(notice.statusText, TranscriptOutcome.noSpeech.label)
        XCTAssertNil(notice.settingsDetail)
    }

    func testEmptyEngineTextReadsAsNoSpeech() {
        XCTAssertEqual(TakeCompletionNotice.resolve(isPartial: false, processedText: "").statusText, "No speech detected")
        XCTAssertEqual(TakeCompletionNotice.resolve(isPartial: true, processedText: "").statusText, "No speech detected")
    }
}
