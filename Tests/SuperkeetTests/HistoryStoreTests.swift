import XCTest
@testable import Superkeet

final class HistoryStoreTests: XCTestCase {

    private func makeStore() -> (dir: URL, store: HistoryStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = HistoryStore(fileURL: dir.appendingPathComponent("history.json"))
        return (dir, store)
    }

    private func makeRecord(_ text: String) -> TranscriptionRecord {
        TranscriptionRecord(
            text: text,
            durationSeconds: 1.0,
            activeAppName: "TestApp",
            activeAppBundleId: "com.test.app"
        )
    }

    func testEmptyStoreHasNoRecords() {
        let (dir, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(store.records.isEmpty)
    }

    func testAddRecordInsertsAtFront() {
        let (dir, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.addRecord(makeRecord("first"))
        store.addRecord(makeRecord("second"))
        XCTAssertEqual(store.records.count, 2)
        XCTAssertEqual(store.records.first?.text, "second")
    }

    func testDeleteRecord() {
        let (dir, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let record = makeRecord("hello")
        store.addRecord(record)
        store.deleteRecord(record)
        XCTAssertTrue(store.records.isEmpty)
    }

    func testClearHistory() {
        let (dir, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.addRecord(makeRecord("a"))
        store.addRecord(makeRecord("b"))
        store.clearHistory()
        XCTAssertTrue(store.records.isEmpty)
    }

    func testMaxRecordsPruning() {
        let (dir, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        for index in 0..<1005 {
            store.addRecord(makeRecord("rec\(index)"))
        }
        XCTAssertEqual(store.records.count, 1000)
    }

    func testPersistenceRoundTrip() {
        let (dir, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.addRecord(makeRecord("persisted text"))
        store.flushPendingSave()

        let reloaded = HistoryStore(fileURL: dir.appendingPathComponent("history.json"))
        XCTAssertEqual(reloaded.records.count, 1)
        XCTAssertEqual(reloaded.records.first?.text, "persisted text")
    }

    func testDeletePersistsAcrossReload() {
        let (dir, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let record = makeRecord("to delete")
        store.addRecord(makeRecord("keep"))
        store.addRecord(record)
        store.deleteRecord(record)
        store.flushPendingSave()

        let reloaded = HistoryStore(fileURL: dir.appendingPathComponent("history.json"))
        XCTAssertEqual(reloaded.records.count, 1)
        XCTAssertEqual(reloaded.records.first?.text, "keep")
    }

    func testFilePermissionsAreRestricted() {
        let (dir, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.addRecord(makeRecord("perm check"))
        store.flushPendingSave()

        let path = dir.appendingPathComponent("history.json").path
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let permissions = (attrs?[.posixPermissions] as? Int)
        XCTAssertEqual(permissions, 0o600)
    }

    func testLoadingCorruptFileDoesNotCrash() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let path = dir.appendingPathComponent("history.json")
        try? Data("not valid json".utf8).write(to: path)

        let reloaded = HistoryStore(fileURL: path)
        XCTAssertTrue(reloaded.records.isEmpty)
    }
}
