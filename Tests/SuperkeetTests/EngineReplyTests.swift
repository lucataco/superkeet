import XCTest
@testable import Superkeet

final class EngineReplyTests: XCTestCase {
    func testAcknowledgementDecodes() throws {
        let reply = try XCTUnwrap(EngineReply(decoding: #"{"status":"ok","state":"recording","session_id":"abc","protocol_version":2}"#))
        XCTAssertTrue(reply.isOK)
        XCTAssertEqual(reply.state, "recording")
        XCTAssertEqual(reply.sessionID, "abc")
        XCTAssertEqual(reply.protocolVersion, 2)
        XCTAssertNil(reply.rejection)
    }

    func testErrorReplyCarriesTheEngineReason() throws {
        let reply = try XCTUnwrap(EngineReply(decoding:
            #"{"status":"error","message":"Could not start audio capture: Input device 'USB Mic' not found","protocol_version":2}"#))
        XCTAssertFalse(reply.isOK)
        XCTAssertEqual(reply.rejection, "Could not start audio capture: Input device 'USB Mic' not found")
    }

    func testErrorReplyWithoutMessageStillCountsAsRefusal() throws {
        let reply = try XCTUnwrap(EngineReply(decoding: #"{"status":"error","message":"  "}"#))
        XCTAssertEqual(reply.rejection, "The speech engine refused the request.")
        XCTAssertEqual(EngineReply(decoding: #"{"status":"error"}"#)?.rejection, "The speech engine refused the request.")
    }

    func testMissingOrGarbledReplyMeansNoAnswer() {
        XCTAssertNil(EngineReply(decoding: nil))
        XCTAssertNil(EngineReply(decoding: ""))
        XCTAssertNil(EngineReply(decoding: "not json"))
        XCTAssertNil(EngineReply(decoding: #"{"state":"idle"}"#))
    }
}
