import XCTest
@testable import Superkeet

@MainActor
final class ParakeetInterimTranscriptTests: XCTestCase {
    func testSupportedProtocolsAndInterimCapability() {
        XCTAssertEqual(ParakeetService.supportedProtocolVersions, [1, 2])
        XCTAssertEqual(ParakeetService.interimTextProtocolVersion, 2)
        XCTAssertTrue(ParakeetService.supportedProtocolVersions.contains(ParakeetService.interimTextProtocolVersion))
    }

    func testCompletionTimeoutScalesWithRecordingLength() {
        // Short takes fail fast instead of blocking recording for minutes.
        XCTAssertEqual(ParakeetService.completionTimeout(forRecordingDuration: 0), 20)
        XCTAssertEqual(ParakeetService.completionTimeout(forRecordingDuration: 3), 20)
        XCTAssertEqual(ParakeetService.completionTimeout(forRecordingDuration: 30), 60)
        // Long takes still get generous headroom, capped at the historical five minutes.
        XCTAssertEqual(ParakeetService.completionTimeout(forRecordingDuration: 600), 300)
    }

    func testInterimStreamsAreKeyedBySessionAndEndExplicitly() async {
        let service = ParakeetService.shared
        let first = service.interimTranscripts(sessionID: "interim-a")
        let second = service.interimTranscripts(sessionID: "interim-b")

        let collector = Task { () -> [String] in
            var seen: [String] = []
            for await transcript in first { seen.append(transcript.text) }
            return seen
        }
        let other = Task { () -> [String] in
            var seen: [String] = []
            for await transcript in second { seen.append(transcript.text) }
            return seen
        }
        service.endInterimTranscripts(sessionID: "interim-a")
        let firstSeen = await collector.value
        XCTAssertEqual(firstSeen, [])
        service.endInterimTranscripts(sessionID: "interim-b")
        let secondSeen = await other.value
        XCTAssertEqual(secondSeen, [])
        service.endInterimTranscripts(sessionID: "interim-a")
        service.endInterimTranscripts(sessionID: "never-opened")
    }

    func testOpeningASessionTwiceReplacesTheEarlierConsumer() async {
        let service = ParakeetService.shared
        let stale = service.interimTranscripts(sessionID: "interim-c")
        let staleEnded = Task { () -> Bool in
            for await _ in stale { return false }
            return true
        }
        _ = service.interimTranscripts(sessionID: "interim-c")
        let ended = await staleEnded.value
        XCTAssertTrue(ended, "The replaced stream finishes so its consumer does not hang.")
        service.endInterimTranscripts(sessionID: "interim-c")
    }
}
