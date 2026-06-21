import XCTest
@testable import Superkeet

final class NDJSONLineBufferTests: XCTestCase {

    func testEmptyDataProducesNoLines() {
        let buffer = NDJSONLineBuffer()
        XCTAssertTrue(buffer.consume(Data()).isEmpty)
    }

    func testSingleCompleteLine() {
        let buffer = NDJSONLineBuffer()
        let lines = buffer.consume(Data("{\"type\":\"start\"}\n".utf8))
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(String(data: lines[0], encoding: .utf8), "{\"type\":\"start\"}")
    }

    func testMultipleCompleteLinesInOneChunk() {
        let buffer = NDJSONLineBuffer()
        let raw = "{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n"
        let lines = buffer.consume(Data(raw.utf8))
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(String(data: lines[0], encoding: .utf8), "{\"a\":1}")
        XCTAssertEqual(String(data: lines[1], encoding: .utf8), "{\"b\":2}")
        XCTAssertEqual(String(data: lines[2], encoding: .utf8), "{\"c\":3}")
    }

    func testPartialLineSplitAcrossChunks() {
        let buffer = NDJSONLineBuffer()
        XCTAssertTrue(buffer.consume(Data("{\"type\":".utf8)).isEmpty)
        let lines = buffer.consume(Data("\"start\"}\n".utf8))
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(String(data: lines[0], encoding: .utf8), "{\"type\":\"start\"}")
    }

    func testMixedCompleteAndPartialInOneChunk() {
        let buffer = NDJSONLineBuffer()
        let lines = buffer.consume(Data("{\"ok\":1}\n{\"partial".utf8))
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(String(data: lines[0], encoding: .utf8), "{\"ok\":1}")

        let more = buffer.consume(Data("\"\":2}\n".utf8))
        XCTAssertEqual(more.count, 1)
        XCTAssertEqual(String(data: more[0], encoding: .utf8), "{\"partial\"\":2}")
    }

    func testDrainRemainderReturnsPartialLine() throws {
        let buffer = NDJSONLineBuffer()
        _ = buffer.consume(Data("{\"incomplete".utf8))
        let remainder = try XCTUnwrap(buffer.drainRemainder())
        XCTAssertEqual(String(data: remainder, encoding: .utf8), "{\"incomplete")
    }

    func testDrainRemainderReturnsNilWhenEmpty() {
        let buffer = NDJSONLineBuffer()
        XCTAssertNil(buffer.drainRemainder())
    }

    func testDrainRemainderReturnsNilAfterAllLinesConsumed() {
        let buffer = NDJSONLineBuffer()
        _ = buffer.consume(Data("{\"ok\":1}\n".utf8))
        XCTAssertNil(buffer.drainRemainder())
    }

    func testEmptyLinesArePreservedAsEmptyData() {
        let buffer = NDJSONLineBuffer()
        let lines = buffer.consume(Data("\n\n".utf8))
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].count, 0)
        XCTAssertEqual(lines[1].count, 0)
    }

    func testThreadSafeInterleavedConsumes() {
        let buffer = NDJSONLineBuffer()
        let queue = DispatchQueue(label: "test", attributes: .concurrent)
        let expectation = expectation(description: "all chunks consumed")
        let chunkCount = 100
        var totalLines: Int = 0
        var completed: Int = 0
        let lock = NSLock()

        for index in 0..<chunkCount {
            queue.async {
                let lines = buffer.consume(Data("line\(index)\n".utf8))
                lock.lock()
                totalLines += lines.count
                completed += 1
                if completed == chunkCount {
                    expectation.fulfill()
                }
                lock.unlock()
            }
        }

        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(totalLines, chunkCount)
    }
}
