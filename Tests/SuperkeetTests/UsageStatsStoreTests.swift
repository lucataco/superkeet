import XCTest
@testable import Superkeet

final class UsageStatsStoreTests: XCTestCase {

    private func makeStore() -> (dir: URL, store: UsageStatsStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = UsageStatsStore(fileURL: dir.appendingPathComponent("usage-stats.json"))
        return (dir, store)
    }

    func testEmptyStoreHasNoData() {
        let (dir, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(store.hasData)
        XCTAssertEqual(store.totalWords, 0)
        XCTAssertEqual(store.totalSessions, 0)
        XCTAssertEqual(store.totalSeconds, 0, accuracy: 0.001)
    }

    func testRecordCreatesBucket() {
        let (dir, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.record(wordCount: 10, durationSeconds: 30)
        XCTAssertTrue(store.hasData)
        XCTAssertEqual(store.totalWords, 10)
        XCTAssertEqual(store.totalSessions, 1)
        XCTAssertEqual(store.totalSeconds, 30, accuracy: 0.001)
    }

    func testMultipleRecordsSameDayAggregate() {
        let (dir, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.record(wordCount: 10, durationSeconds: 30)
        store.record(wordCount: 20, durationSeconds: 60)
        XCTAssertEqual(store.totalWords, 30)
        XCTAssertEqual(store.totalSessions, 2)
        XCTAssertEqual(store.totalSeconds, 90, accuracy: 0.001)
    }

    func testReset() {
        let (dir, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.record(wordCount: 10, durationSeconds: 30)
        store.reset()
        XCTAssertFalse(store.hasData)
        XCTAssertEqual(store.totalWords, 0)
    }

    func testRecordWithZeroValuesIsIgnored() {
        let (dir, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.record(wordCount: 0, durationSeconds: 0)
        XCTAssertFalse(store.hasData)
    }

    func testAverageWordsPerMinute() {
        let (dir, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.record(wordCount: 100, durationSeconds: 60)
        XCTAssertEqual(store.averageWordsPerMinute, 100, accuracy: 0.001)
    }

    func testAverageWordsPerMinuteIsZeroWhenNoDuration() {
        let (dir, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.record(wordCount: 50, durationSeconds: 0)
        XCTAssertEqual(store.averageWordsPerMinute, 0)
    }

    func testTimeSavedMinutes() {
        let (dir, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Assumed typing speed: 40 WPM
        // 100 words typed would take 2.5 min; speaking took 1 min -> saved 1.5 min
        store.record(wordCount: 100, durationSeconds: 60)
        XCTAssertEqual(store.timeSavedMinutes, 1.5, accuracy: 0.001)
    }

    func testTimeSavedIsNeverNegative() {
        let (dir, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // If speaking took longer than typing would (very slow speech)
        store.record(wordCount: 1, durationSeconds: 120)
        XCTAssertEqual(store.timeSavedMinutes, 0, accuracy: 0.001)
    }

    func testPersistenceRoundTrip() {
        let (dir, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.record(wordCount: 42, durationSeconds: 15)
        store.flushPendingSave()

        let reloaded = UsageStatsStore(fileURL: dir.appendingPathComponent("usage-stats.json"))
        XCTAssertEqual(reloaded.totalWords, 42)
        XCTAssertEqual(reloaded.totalSessions, 1)
        XCTAssertEqual(reloaded.totalSeconds, 15, accuracy: 0.001)
    }

    func testFilePermissionsAreRestricted() {
        let (dir, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.record(wordCount: 1, durationSeconds: 1)
        store.flushPendingSave()

        let path = dir.appendingPathComponent("usage-stats.json").path
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let permissions = (attrs?[.posixPermissions] as? Int)
        XCTAssertEqual(permissions, 0o600)
    }

    func testLoadingCorruptFileDoesNotCrash() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let path = dir.appendingPathComponent("usage-stats.json")
        try? Data("not valid json".utf8).write(to: path)

        let reloaded = UsageStatsStore(fileURL: path)
        XCTAssertFalse(reloaded.hasData)
    }
}
