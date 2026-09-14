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
        store.record(wordCount: 100, durationSeconds: 60)
        XCTAssertEqual(store.timeSavedMinutes, 1.5, accuracy: 0.001)
    }

    func testTimeSavedIsNeverNegative() {
        let (dir, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
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

    func testFailedLoadPreservesFileOnQuitAndBeforeNewSave() throws {
        let (dir, _) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("usage-stats.json")
        let original = Data("{\"2026-09-14\":{\"words\":42,\"seconds\":15,\"sessions\":1},\"broken\":null}".utf8)
        try original.write(to: path)
        let store = UsageStatsStore(fileURL: path)
        XCTAssertNotNil(store.persistenceIssue)
        store.flushPendingSave()
        XCTAssertEqual(try Data(contentsOf: path), original)
        store.record(wordCount: 10, durationSeconds: 5)
        store.flushPendingSave()
        let backup = try XCTUnwrap(store.recoveryBackupURL)
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertEqual(UsageStatsStore(fileURL: path).totalWords, 10)
        store.reset()
        store.flushPendingSave()
        XCTAssertEqual(try Data(contentsOf: backup), original)
    }

    func testUntouchedEmptyStoreDoesNotCreateFileOnQuit() {
        let (dir, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.flushPendingSave()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("usage-stats.json").path))
    }

    func testStreakIsZeroWithNoData() {
        let (dir, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(store.currentStreak, 0)
    }

    func testStreakCountsThroughToday() throws {
        let (dir, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date())
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let dayBefore = try XCTUnwrap(calendar.date(byAdding: .day, value: -2, to: today))

        store.record(wordCount: 5, durationSeconds: 5, on: dayBefore)
        store.record(wordCount: 5, durationSeconds: 5, on: yesterday)
        store.record(wordCount: 5, durationSeconds: 5, on: today)

        XCTAssertEqual(store.currentStreak, 3)
    }

    func testStreakRollsBackToYesterdayWhenTodayHasNoActivity() throws {
        let (dir, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date())
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let dayBefore = try XCTUnwrap(calendar.date(byAdding: .day, value: -2, to: today))

        store.record(wordCount: 5, durationSeconds: 5, on: dayBefore)
        store.record(wordCount: 5, durationSeconds: 5, on: yesterday)

        XCTAssertEqual(store.currentStreak, 2)
    }

    func testStreakBreaksAfterAFullInactiveDay() throws {
        let (dir, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date())
        let threeDaysAgo = try XCTUnwrap(calendar.date(byAdding: .day, value: -3, to: today))

        store.record(wordCount: 5, durationSeconds: 5, on: threeDaysAgo)

        XCTAssertEqual(store.currentStreak, 0)
    }

    func testStreakDoesNotBridgeGaps() throws {
        let (dir, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date())
        let dayBefore = try XCTUnwrap(calendar.date(byAdding: .day, value: -2, to: today))
        let threeDaysAgo = try XCTUnwrap(calendar.date(byAdding: .day, value: -3, to: today))

        store.record(wordCount: 5, durationSeconds: 5, on: threeDaysAgo)
        store.record(wordCount: 5, durationSeconds: 5, on: dayBefore)

        XCTAssertEqual(store.currentStreak, 0)
    }
}
