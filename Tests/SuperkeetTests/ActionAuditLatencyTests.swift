import XCTest
@testable import Superkeet

final class ActionAuditLatencyTests: XCTestCase {
    private func makeStore() -> (dir: URL, store: ActionAuditStore) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, ActionAuditStore(fileURL: dir.appendingPathComponent("action-audit.log")))
    }

    func testEntriesCarryLatencyOnlyInsideATimeline() {
        let (dir, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.record(serverName: "a", toolName: "before", risk: .readOnly, argumentsJSON: "{}", outcome: "succeeded")
        store.beginTimeline(at: Date().addingTimeInterval(-1.5))
        store.record(serverName: "a", toolName: "during", risk: .readOnly, argumentsJSON: "{}", outcome: "succeeded", durationMs: 42)
        store.endTimeline()
        store.record(serverName: "a", toolName: "after", risk: .readOnly, argumentsJSON: "{}", outcome: "succeeded")

        let entries = store.entries()
        XCTAssertEqual(entries.map(\.toolName), ["before", "during", "after"])
        XCTAssertNil(entries[0].sinceCommandMs)
        XCTAssertGreaterThanOrEqual(entries[1].sinceCommandMs ?? -1, 1_500)
        XCTAssertLessThan(entries[1].sinceCommandMs ?? .max, 10_000)
        XCTAssertEqual(entries[1].durationMs, 42)
        XCTAssertNil(entries[2].sinceCommandMs)
        XCTAssertNil(entries[2].durationMs)
    }

    func testRecordingStartMarkSurvivesTheRunStart() {
        let (dir, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.beginTimeline(at: Date().addingTimeInterval(-3), replacing: true)
        store.beginTimeline(replacing: false)
        store.record(serverName: "superkeet", toolName: "open_app", risk: .mutating, argumentsJSON: "{}", outcome: "succeeded")
        XCTAssertGreaterThanOrEqual(store.entries().first?.sinceCommandMs ?? -1, 3_000)

        store.beginTimeline(at: Date(), replacing: true)
        store.record(serverName: "superkeet", toolName: "open_app", risk: .mutating, argumentsJSON: "{}", outcome: "succeeded")
        XCTAssertLessThan(store.entries().last?.sinceCommandMs ?? .max, 1_000)
    }

    func testEntriesWrittenBeforeLatencyFieldsStillDecode() throws {
        let (dir, store) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let legacy = #"{"timestamp":"2026-09-19T23:24:52Z","serverName":"superkeet","toolName":"open_app","risk":"mutating","arguments":"{}","outcome":"succeeded"}"#
        try (legacy + "\n").write(to: store.logFileURL, atomically: true, encoding: .utf8)

        let entries = store.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries.first?.sinceCommandMs)
        XCTAssertNil(entries.first?.durationMs)
    }

    func testDurationRounding() {
        XCTAssertEqual(ActionToolRouter.milliseconds(.milliseconds(1_250)), 1_250)
        XCTAssertEqual(ActionToolRouter.milliseconds(.zero), 0)
        XCTAssertEqual(ActionToolRouter.milliseconds(.microseconds(999)), 0)
    }
}
