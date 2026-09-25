import XCTest
import Combine
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

    func testFailedLoadDoesNotOverwriteOriginalOnQuitAndBacksUpBeforeNewSave() throws {
        let (dir, _) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("history.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let valid = try XCTUnwrap(String(data: encoder.encode(makeRecord("recoverable")), encoding: .utf8))
        let original = Data("[\(valid), {\"malformed\": true}]".utf8)
        try original.write(to: path)
        let store = HistoryStore(fileURL: path)
        XCTAssertNotNil(store.persistenceIssue)
        store.flushPendingSave()
        XCTAssertEqual(try Data(contentsOf: path), original)
        XCTAssertNil(store.recoveryBackupURL)

        store.addRecord(makeRecord("new history"))
        store.flushPendingSave()
        let backup = try XCTUnwrap(store.recoveryBackupURL)
        XCTAssertEqual(try Data(contentsOf: backup), original)
        let attributes = try FileManager.default.attributesOfItem(atPath: backup.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(HistoryStore(fileURL: path).records.first?.text, "new history")
        store.clearHistory()
        store.flushPendingSave()
        XCTAssertEqual(try Data(contentsOf: backup), original)
    }

    func testOneUnreadableRecordDoesNotHideTheRest() throws {
        let (dir, _) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("history.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let valid = try XCTUnwrap(String(data: encoder.encode(makeRecord("kept")), encoding: .utf8))
        try Data("[\(valid), {\"malformed\": true}]".utf8).write(to: path)
        let store = HistoryStore(fileURL: path)
        XCTAssertEqual(store.records.map(\.text), ["kept"])
        XCTAssertTrue(store.persistenceIssue?.contains("1 history entry") ?? false)
    }

    func testRecordWithMissingFieldsStillLoads() throws {
        let (dir, _) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("history.json")
        try Data(#"[{"text":"hello there world","timestamp":"2026-01-02T03:04:05Z"}]"#.utf8).write(to: path)
        let store = HistoryStore(fileURL: path)
        let record = try XCTUnwrap(store.records.first)
        XCTAssertEqual(record.text, "hello there world")
        XCTAssertEqual(record.wordCount, 3, "Derived from the text when missing.")
        XCTAssertEqual(record.activeAppName, "")
        XCTAssertNil(store.persistenceIssue)
    }

    func testBackupFailureLeavesOriginalUntouched() throws {
        let (dir, _) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("history.json")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        let sentinel = path.appendingPathComponent("keep")
        try Data("original".utf8).write(to: sentinel)
        let store = HistoryStore(fileURL: path)
        store.addRecord(makeRecord("new history"))
        store.flushPendingSave()
        XCTAssertNotNil(store.persistenceIssue)
        XCTAssertNil(store.recoveryBackupURL)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("original".utf8))
    }

    func testUntouchedEmptyStoreDoesNotCreateFileOnQuit() {
        let (dir, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.flushPendingSave()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("history.json").path))
    }

    @MainActor
    func testDebouncedSaveAfterFailedLoadPreservesOriginal() async throws {
        let (dir, _) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("history.json")
        let original = Data("malformed history".utf8)
        try original.write(to: path)
        let store = HistoryStore(fileURL: path)
        let saved = expectation(description: "Debounced save completed with backup")
        let observation = store.$recoveryBackupURL.compactMap { $0 }.first().sink { _ in saved.fulfill() }
        defer { observation.cancel() }
        store.addRecord(makeRecord("saved asynchronously"))
        await fulfillment(of: [saved], timeout: 3)
        let backup = try XCTUnwrap(store.recoveryBackupURL)
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertEqual(HistoryStore(fileURL: path).records.first?.text, "saved asynchronously")
    }
}
