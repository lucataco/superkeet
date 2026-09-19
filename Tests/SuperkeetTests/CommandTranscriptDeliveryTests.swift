import XCTest
@testable import Superkeet

final class CommandTranscriptDeliveryTests: XCTestCase {
    func testCompleteCommandUsesOnlyLiteralReplacements() {
        let event = TranscriptEvent(type: "complete", sessionID: "test", text: "Um, open categolabs.com. Scratch that.", status: "ok")
        let rules = [PhraseReplacement(phrase: "categolabs", replacement: "catacolabs")]
        XCTAssertEqual(CommandTranscriptDelivery.decide(event: event, commandMode: true, replacements: rules, bundleID: ""),
                       .command("Um, open catacolabs.com. Scratch that."))
    }

    func testCommandReplacementsHonorRecordingAppScope() {
        let event = TranscriptEvent(type: "complete", sessionID: "test", text: "open categolabs.com", status: "ok")
        let rules = [PhraseReplacement(phrase: "categolabs", replacement: "catacolabs", bundleID: "browser")]
        XCTAssertEqual(CommandTranscriptDelivery.decide(event: event, commandMode: true, replacements: rules, bundleID: "browser"),
                       .command("open catacolabs.com"))
        XCTAssertEqual(CommandTranscriptDelivery.decide(event: event, commandMode: true, replacements: rules, bundleID: "other"),
                       .command("open categolabs.com"))
    }

    func testPartialCommandsNeverBecomeDictationOrExecute() {
        for event in [
            TranscriptEvent(type: "complete", sessionID: "test", text: "open Discord", status: "partial"),
            TranscriptEvent(type: "complete", sessionID: "test", text: "open Discord", status: "ok", failedSegments: 1),
            TranscriptEvent(type: "complete", sessionID: "test", text: "open Discord", status: "ok", droppedSamples: 10),
            TranscriptEvent(type: "complete", sessionID: "test", text: "open Discord", status: "error", message: "Engine failure"),
            TranscriptEvent(type: "complete", sessionID: "test", text: "", status: "partial")
        ] {
            let delivery = CommandTranscriptDelivery.decide(event: event, commandMode: true, replacements: [], bundleID: "")
            guard case .failure(let message) = delivery else { return XCTFail("Incomplete commands must fail, got \(delivery)") }
            XCTAssertTrue(message.contains("Please try again"))
        }
    }

    func testEmptyCommandStaysOutOfDictation() {
        for text in ["", " \n "] {
            let event = TranscriptEvent(type: "complete", sessionID: "test", text: text, status: "empty")
            XCTAssertEqual(CommandTranscriptDelivery.decide(event: event, commandMode: true, replacements: [], bundleID: ""), .empty)
        }
    }

    func testNormalAndPartialDictationKeepDictationRoute() {
        for status in ["ok", "partial", "error"] {
            let event = TranscriptEvent(type: "complete", sessionID: "test", text: "some dictation", status: status)
            XCTAssertEqual(CommandTranscriptDelivery.decide(event: event, commandMode: false, replacements: [], bundleID: ""), .dictation)
        }
    }
}
