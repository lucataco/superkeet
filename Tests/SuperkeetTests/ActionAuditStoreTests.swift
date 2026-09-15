import XCTest
@testable import Superkeet

final class ActionAuditStoreTests: XCTestCase {
    private func makeStore() -> (dir: URL, store: ActionAuditStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ActionAuditStore(fileURL: dir.appendingPathComponent("action-audit.log"))
        return (dir, store)
    }

    func testRecordWritesRedactedEntry() {
        let (dir, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.record(
            serverName: "browser",
            toolName: "navigate",
            risk: .mutating,
            argumentsJSON: #"{"url":"https://example.com","token":"super-secret"}"#,
            outcome: "succeeded",
            detail: "opened"
        )

        let entries = store.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.toolName, "navigate")
        XCTAssertEqual(entries.first?.risk, "mutating")
        XCTAssertFalse(entries.first?.arguments.contains("super-secret") ?? true)
        XCTAssertTrue(entries.first?.arguments.contains("example.com") ?? false)
    }

    func testMultipleRecordsAppend() {
        let (dir, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.record(serverName: "a", toolName: "one", risk: .readOnly, argumentsJSON: "{}", outcome: "succeeded")
        store.record(serverName: "a", toolName: "two", risk: .readOnly, argumentsJSON: "{}", outcome: "denied")

        let entries = store.entries()
        XCTAssertEqual(entries.map(\.toolName), ["one", "two"])
    }

    func testPrunesToMaximumEntryCountKeepingNewest() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ActionAuditStore(
            fileURL: dir.appendingPathComponent("action-audit.log"),
            maxEntries: 3,
            maxBytes: 10_000_000
        )
        for index in 0..<6 {
            store.record(serverName: "a", toolName: "tool\(index)", risk: .readOnly, argumentsJSON: "{}", outcome: "succeeded")
        }

        XCTAssertEqual(store.entries().map(\.toolName), ["tool3", "tool4", "tool5"])
    }

    func testPrunesToMaximumBytesKeepingNewest() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ActionAuditStore(
            fileURL: dir.appendingPathComponent("action-audit.log"),
            maxEntries: 1_000,
            maxBytes: 200
        )
        for index in 0..<5 {
            store.record(
                serverName: "a",
                toolName: "tool\(index)",
                risk: .readOnly,
                argumentsJSON: "{}",
                outcome: "succeeded",
                detail: String(repeating: "x", count: 80)
            )
        }

        let entries = store.entries()
        XCTAssertFalse(entries.isEmpty)
        XCTAssertEqual(entries.last?.toolName, "tool4")
        XCTAssertLessThan(entries.count, 5)
    }
}
