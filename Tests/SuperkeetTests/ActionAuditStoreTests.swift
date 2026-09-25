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
            XCTAssertLessThanOrEqual(store.entries().count, 3, "never exceeds the limit")
        }

        // Pruning keeps a contiguous run of the newest entries.
        let names = store.entries().map(\.toolName)
        XCTAssertEqual(names.last, "tool5")
        XCTAssertEqual(names, (6 - names.count..<6).map { "tool\($0)" })
    }

    func testPruningLeavesHeadroomSoTheNextAppendDoesNotRewrite() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("action-audit.log")

        let store = ActionAuditStore(fileURL: url, maxEntries: 100, maxBytes: 10_000_000)
        for index in 0...100 {
            store.record(serverName: "a", toolName: "tool\(index)", risk: .readOnly, argumentsJSON: "{}", outcome: "succeeded")
        }
        XCTAssertEqual(store.entries().count, ActionAuditStore.pruneTarget(for: 100))

        // A pruning rewrite replaces the file atomically (new inode); a plain append does not.
        let inodeBefore = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
        store.record(serverName: "a", toolName: "next", risk: .readOnly, argumentsJSON: "{}", outcome: "succeeded")
        let inodeAfter = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
        XCTAssertEqual(inodeBefore, inodeAfter)
        XCTAssertEqual(store.entries().last?.toolName, "next")
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

    func testAuditBoundaryPreservesGenericTitleQueryButRedactsSecretsBeforeTruncation() throws {
        let (dir, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.record(serverName: "fixture", toolName: "search", risk: .readOnly,
                     argumentsJSON: #"{"title":"DNS records","query":"catacolabs.com","token":"fixture-token"}"#, outcome: "succeeded",
                     detail: "password=\"" + String(repeating: "private-secret ", count: 1_000) + "\" public suffix")
        let entry = try XCTUnwrap(store.entries().first)
        XCTAssertTrue(entry.arguments.contains("catacolabs.com"))
        XCTAssertTrue(entry.arguments.contains("DNS records"))
        XCTAssertFalse(entry.arguments.contains("fixture-token"))
        XCTAssertFalse(entry.detail?.contains("private-secret") == true)
        XCTAssertTrue(entry.detail?.contains("public suffix") == true)
    }
}
