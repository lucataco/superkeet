import OSLog
import XCTest
@testable import Superkeet

final class LogExporterTests: XCTestCase {
    func testRendersHeaderAndLines() {
        let line = LogExporter.Line(date: Date(timeIntervalSince1970: 0), level: "error", category: "ParakeetService", message: "boom")
        let text = LogExporter.render([line], header: "Superkeet Diagnostics")
        XCTAssertTrue(text.hasPrefix("Superkeet Diagnostics\n"))
        XCTAssertTrue(text.contains("Log (1 entries since launch)"))
        XCTAssertTrue(text.contains("1970-01-01T00:00:00.000Z [error] ParakeetService: boom"))
    }

    func testCollectsThisProcessesOwnMessages() throws {
        let marker = "log-export-probe-\(UUID().uuidString)"
        Logger(subsystem: LogExporter.subsystem, category: "Test").error("\(marker, privacy: .public)")
        let lines = try LogExporter.collect(since: Date().addingTimeInterval(-60))
        XCTAssertTrue(lines.contains { $0.message.contains(marker) && $0.level == "error" && $0.category == "Test" })
    }
}
