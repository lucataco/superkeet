import XCTest
@testable import Superkeet

final class DownloadCollectorTests: XCTestCase {

    func testErrorMessageDefaultsToNil() {
        let collector = DownloadCollector()
        XCTAssertNil(collector.errorMessage)
    }

    func testErrorMessageSetAndGet() {
        let collector = DownloadCollector()
        collector.errorMessage = "download failed"
        XCTAssertEqual(collector.errorMessage, "download failed")
    }

    func testStderrExcerptIsNilWhenEmpty() {
        let collector = DownloadCollector()
        XCTAssertNil(collector.stderrExcerpt())
    }

    func testStderrExcerptReturnsTrimmedText() {
        let collector = DownloadCollector()
        collector.appendStderr(Data("  some error  \n".utf8))
        XCTAssertEqual(collector.stderrExcerpt(), "some error")
    }

    func testStderrAccumulatesAcrossAppends() {
        let collector = DownloadCollector()
        collector.appendStderr(Data("line1\n".utf8))
        collector.appendStderr(Data("line2\n".utf8))
        let excerpt = collector.stderrExcerpt()
        XCTAssertNotNil(excerpt)
        XCTAssertTrue(excerpt?.contains("line1") == true)
        XCTAssertTrue(excerpt?.contains("line2") == true)
    }

    func testStderrTruncatesToTailKeepLast8192Bytes() {
        let collector = DownloadCollector()
        // Write 10 chunks of 1001 bytes each (10010 total > 8192 limit)
        let chunk = String(repeating: "x", count: 1000) + "\n"
        for _ in 0..<10 {
            collector.appendStderr(Data(chunk.utf8))
        }
        let excerpt = collector.stderrExcerpt()
        XCTAssertNotNil(excerpt)
        XCTAssertFalse(excerpt?.isEmpty == true)
        // After trimming whitespace, should be <= 8192 characters
        XCTAssertLessThanOrEqual(excerpt?.count ?? 0, 8192)
    }

    func testStderrExcerptHandlesInvalidUTF8Gracefully() {
        let collector = DownloadCollector()
        collector.appendStderr(Data([0xFF, 0xFE, 0x00]))
        // Should not crash; returns either nil or a replacement-char string
        _ = collector.stderrExcerpt()
    }
}
