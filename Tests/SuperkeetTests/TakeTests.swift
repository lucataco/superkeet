import XCTest
@testable import Superkeet

final class TakeTests: XCTestCase {
    private func take(_ phases: Take.Phase..., kind: Take.Kind = .dictation) -> Take {
        var take = Take(kind: kind, trigger: .toggle)
        for phase in phases { XCTAssertTrue(take.advance(to: phase), "could not reach \(phase)") }
        return take
    }

    func testANewTakeIsRequestedAndHasNoEngineSession() {
        let take = Take(kind: .command, trigger: .pushToTalk)
        XCTAssertEqual(take.phase, .requested)
        XCTAssertTrue(take.isPending)
        XCTAssertTrue(take.isOpen)
        XCTAssertNil(take.liveSessionID)
        XCTAssertEqual(take.sessionID, take.id.uuidString)
    }

    func testTheUsualPathRunsRequestedToTranscribing() {
        var take = Take(kind: .dictation, trigger: .toggle)
        XCTAssertTrue(take.advance(to: .starting))
        XCTAssertTrue(take.isPending)
        XCTAssertTrue(take.advance(to: .recording))
        XCTAssertFalse(take.isPending)
        XCTAssertTrue(take.isOpen)
        XCTAssertTrue(take.advance(to: .transcribing))
        XCTAssertFalse(take.isOpen)
        XCTAssertEqual(take.liveSessionID, take.sessionID)
    }

    func testPhasesCannotBeSkippedOrReversed() {
        var requested = take()
        XCTAssertFalse(requested.advance(to: .recording))
        XCTAssertFalse(requested.advance(to: .transcribing))
        XCTAssertFalse(requested.advance(to: .cancelling))
        XCTAssertEqual(requested.phase, .requested)

        var transcribing = take(.starting, .recording, .transcribing)
        XCTAssertFalse(transcribing.advance(to: .recording))
        XCTAssertFalse(transcribing.advance(to: .starting))
        XCTAssertEqual(transcribing.phase, .transcribing)
    }

    func testAnyTakeTheEngineKnowsAboutCanBeCancelledOnce() {
        for reached in [[Take.Phase.starting], [.starting, .recording], [.starting, .recording, .transcribing]] {
            var take = Take(kind: .dictation, trigger: .toggle)
            reached.forEach { take.advance(to: $0) }
            XCTAssertTrue(take.advance(to: .cancelling))
            XCTAssertFalse(take.advance(to: .cancelling))
            XCTAssertFalse(take.advance(to: .recording))
            XCTAssertFalse(take.isOpen)
        }
    }

    func testOnlyALiveTakeAcceptsItsOwnEngineOutput() {
        let recording = take(.starting, .recording)
        let mine = TranscriptEvent(type: "complete", sessionID: recording.sessionID, text: "first", status: "ok")
        let other = TranscriptEvent(type: "complete", sessionID: "someone-else", text: "first", status: "ok")
        XCTAssertTrue(recording.accepts(mine))
        XCTAssertFalse(recording.accepts(other))

        var cancelled = recording
        cancelled.advance(to: .cancelling)
        XCTAssertFalse(cancelled.accepts(mine), "late output from a cancelled take must be dropped")

        let requested = Take(id: recording.id, kind: .dictation, trigger: .toggle)
        XCTAssertFalse(requested.accepts(mine))
    }

    func testKindAndTriggerSurviveEveryPhase() {
        var take = Take(kind: .dictation, trigger: .pushToTalk)
        for phase in [Take.Phase.starting, .recording, .transcribing, .cancelling] {
            take.advance(to: phase)
            XCTAssertEqual(take.kind, .dictation)
            XCTAssertEqual(take.trigger, .pushToTalk)
        }
    }
}
