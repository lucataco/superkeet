import XCTest
@testable import Superkeet

/// The speech service's protocol-2 interim-text plumbing, exercised through
/// its public API (the service is a singleton, so no daemon is involved here).
@MainActor
final class ParakeetInterimTranscriptTests: XCTestCase {
    func testSupportedProtocolsAndInterimCapability() {
        XCTAssertEqual(ParakeetService.supportedProtocolVersions, [1, 2])
        XCTAssertEqual(ParakeetService.interimTextProtocolVersion, 2)
        XCTAssertTrue(ParakeetService.supportedProtocolVersions.contains(ParakeetService.interimTextProtocolVersion))
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
        // Ending one session finishes only its own stream.
        service.endInterimTranscripts(sessionID: "interim-a")
        let firstSeen = await collector.value
        XCTAssertEqual(firstSeen, [])
        service.endInterimTranscripts(sessionID: "interim-b")
        let secondSeen = await other.value
        XCTAssertEqual(secondSeen, [])
        // Ending an unknown or already-ended session is harmless.
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
