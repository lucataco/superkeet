import XCTest
@testable import Superkeet

final class TranscriptProtocolTests: XCTestCase {
    private func frame(_ text: String, sessionID: String = "one") throws -> Data {
        var bytes = try JSONEncoder().encode(TranscriptEvent(type: "complete", sessionID: sessionID, text: text, status: "ok"))
        bytes.append(0x0A)
        return bytes
    }

    func testUnknownEventTypesDecodeAndAreClassifiedAsUnrecognized() throws {
        var stream = TranscriptEventStream()
        let bytes = Data(#"{"type":"partial_v3","session_id":"one","text":"open the notes"}"#.utf8 + [0x0A])
            + (try frame("open the notes app"))
        let events = try stream.append(bytes)
        XCTAssertEqual(events.map(\.kind), [.unrecognized("partial_v3"), .complete])
        XCTAssertEqual(events.first?.text, "open the notes")
        try stream.finish()
    }

    func testProtocolTwoPartialEventsCarryInterimTranscripts() throws {
        var stream = TranscriptEventStream()
        // Exactly what parakeet-cli 0.1.7 writes for "open the notes app and create a new note".
        let wire = #"{"sequence":1,"session_id":"one","text":"Open the notes up","truncated":false,"type":"partial"}"# + "\n"
            + #"{"sequence":2,"session_id":"one","text":"Open the notes app and create a","truncated":true,"type":"partial"}"# + "\n"
        let events = try stream.append(Data(wire.utf8) + (try frame("Open the notes app and create a new note.")))
        XCTAssertEqual(events.map(\.kind), [.partial, .partial, .complete])
        XCTAssertEqual(events[0].interimTranscript, PartialTranscript(text: "Open the notes up", isFinal: false, sequence: 1))
        XCTAssertEqual(events[1].interimTranscript, PartialTranscript(text: "Open the notes app and create a", isFinal: false, sequence: 2))
        XCTAssertEqual(events[1].truncated, true)
        XCTAssertNil(events[2].interimTranscript, "Only partial events carry interim text.")
        XCTAssertFalse(events[0].isPartial, "An interim event is not a lossy completion.")
        try stream.finish()
    }

    func testMalformedPartialEventsYieldNoInterimTranscript() {
        XCTAssertNil(TranscriptEvent(type: "partial", sessionID: "one", text: "x").interimTranscript, "A partial without a sequence is unusable.")
        XCTAssertNil(TranscriptEvent(type: "partial", sessionID: "one", sequence: 3).interimTranscript, "A partial without text is unusable.")
        XCTAssertNil(TranscriptEvent(type: "partial", sessionID: "one", text: "x", sequence: 0).interimTranscript, "Sequences start at one.")
        XCTAssertEqual(TranscriptEvent(type: "partial", sessionID: "one", text: "x", sequence: 1).kind, .partial)
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
        XCTAssertEqual(TranscriptEvent(type: "session_started", sessionID: "one").kind, .sessionStarted)
        XCTAssertEqual(TranscriptEvent(type: "transcribing", sessionID: "one").kind, .transcribing)
        XCTAssertEqual(TranscriptEvent(type: "complete", sessionID: "one", text: "", status: "ok").kind, .complete)
        XCTAssertEqual(TranscriptEvent(type: "partial", sessionID: "one", text: "open the", sequence: 1).kind, .partial)
        // A still-newer engine may add more; the client must not treat that as a protocol violation.
        XCTAssertEqual(TranscriptEvent(type: "word_timing", sessionID: "one").kind, .unrecognized("word_timing"))
        XCTAssertEqual(TranscriptEvent(type: "", sessionID: "one").kind, .unrecognized(""))
        XCTAssertTrue(TranscriptEvent(type: "complete", sessionID: "one", text: "recovered", status: "error").isPartial)
        XCTAssertTrue(TranscriptEvent(type: "complete", sessionID: "one", text: "recovered", status: "ok", droppedSamples: 1).isPartial)
        XCTAssertFalse(TranscriptEvent(type: "complete", sessionID: "one", text: "full", status: "ok", failedSegments: 0, droppedSamples: 0).isPartial)
    }
}
