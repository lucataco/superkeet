import XCTest
@testable import Superkeet

final class TranscriptProtocolTests: XCTestCase {
    private func frame(_ text: String, sessionID: String = "one") throws -> Data {
        var bytes = try JSONEncoder().encode(TranscriptEvent(type: "complete", sessionID: sessionID, text: text, status: "ok"))
        bytes.append(0x0A)
        return bytes
    }

    func testLongMultilineTranscriptIsDeliveredIntactAsOneMessage() throws {
        let transcript = "BEGIN\n" + String(repeating: "A agreed auth not like 🦜\n", count: 5_000) + "END"
        let bytes = try frame(transcript)
        var stream = TranscriptEventStream()
        var events: [TranscriptEvent] = []
        for offset in stride(from: 0, to: bytes.count, by: 137) {
            events += try stream.append(bytes.subdata(in: offset..<min(offset + 137, bytes.count)))
        }
        try stream.finish()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.text, transcript)
    }

    func testEveryUnicodeByteBoundaryIsSafe() throws {
        let bytes = try frame("café 🦜 中文 e\u{301}\nsecond line")
        for split in 0...bytes.count {
            var stream = TranscriptEventStream()
            let first = try stream.append(Data(bytes.prefix(split)))
            let second = try stream.append(Data(bytes.dropFirst(split)))
            XCTAssertEqual((first + second).map(\.text), ["café 🦜 中文 e\u{301}\nsecond line"])
        }
    }

    func testCoalescedFramesAndIncompleteEOF() throws {
        var stream = TranscriptEventStream()
        let bytes = try frame("first") + frame("second", sessionID: "two")
        XCTAssertEqual(try stream.append(bytes).map(\.text), ["first", "second"])
        _ = try stream.append(Data("{\"type\":".utf8))
        XCTAssertThrowsError(try stream.finish())
    }

    func testOversizeMessageFailsInsteadOfKeepingSuffix() throws {
        var stream = TranscriptEventStream(maximumMessageBytes: 100)
        _ = try stream.append(Data(repeating: 0x61, count: 100))
        XCTAssertThrowsError(try stream.append(Data([0x61])))
    }

    func testMalformedUTF8AndPlainTextAreRejected() {
        for data in [Data([0xFF, 0x0A]), Data("legacy plain text\n".utf8)] {
            var stream = TranscriptEventStream()
            XCTAssertThrowsError(try stream.append(data))
        }
    }

    func testSessionCannotBeOverwrittenAndRejectsLateOrDuplicateOutput() {
        var gate = TranscriptSessionGate()
        let event = TranscriptEvent(type: "complete", sessionID: "one", text: "first", status: "ok")
        XCTAssertTrue(gate.begin("one"))
        XCTAssertFalse(gate.begin("two"))
        XCTAssertTrue(gate.accepts(event))
        gate.close()
        XCTAssertFalse(gate.accepts(event))
        XCTAssertTrue(gate.begin("two"))
        XCTAssertFalse(gate.accepts(event))
    }

    func testLossAndFailureCannotBeMistakenForCompleteSuccess() {
        XCTAssertTrue(TranscriptEvent(type: "complete", sessionID: "one", text: "recovered", status: "error").isPartial)
        XCTAssertTrue(TranscriptEvent(type: "complete", sessionID: "one", text: "recovered", status: "ok", droppedSamples: 1).isPartial)
        XCTAssertFalse(TranscriptEvent(type: "complete", sessionID: "one", text: "full", status: "ok", failedSegments: 0, droppedSamples: 0).isPartial)
    }
}
