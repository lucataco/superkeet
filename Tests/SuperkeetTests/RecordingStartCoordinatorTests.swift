import XCTest
@testable import Superkeet

final class RecordingStartCoordinatorTests: XCTestCase {
    @MainActor
    func testSecondToggleCancellationPreventsRecordingAfterDelayedStartup() async throws {
        let coordinator = RecordingStartCoordinator()
        let id = try XCTUnwrap(coordinator.begin())
        let preparing = expectation(description: "Engine startup suspended")
        var resume: CheckedContinuation<Void, Never>?
        var starts = 0
        let task = Task {
            try await coordinator.run(id, prepare: {
                await withCheckedContinuation { resume = $0; preparing.fulfill() }
            }, start: { starts += 1; return true })
        }
        await fulfillment(of: [preparing], timeout: 2)
        coordinator.cancel()
        resume?.resume()
        let started = try await task.value
        XCTAssertFalse(started)
        XCTAssertEqual(starts, 0)
        XCTAssertNil(coordinator.requestID)
    }

    @MainActor
    func testNewRequestCannotReviveCancelledStartup() async throws {
        let coordinator = RecordingStartCoordinator()
        let oldID = try XCTUnwrap(coordinator.begin())
        let preparing = expectation(description: "Old startup suspended")
        var resume: CheckedContinuation<Void, Never>?
        var starts = 0
        let old = Task {
            try await coordinator.run(oldID, prepare: {
                await withCheckedContinuation { resume = $0; preparing.fulfill() }
            }, start: { starts += 1; return true })
        }
        await fulfillment(of: [preparing], timeout: 2)
        coordinator.cancel()
        let newID = try XCTUnwrap(coordinator.begin())
        resume?.resume()
        let oldStarted = try await old.value
        XCTAssertFalse(oldStarted)
        XCTAssertTrue(coordinator.isCurrent(newID))
        let newStarted = try await coordinator.run(newID, prepare: {}, start: { starts += 1; return true })
        XCTAssertTrue(newStarted)
        XCTAssertEqual(starts, 1)
    }

    func testToggleConsumesAutorepeatButAllowsNextFreshPress() {
        XCTAssertEqual(ToggleHotkeyPolicy.action(isKeyDown: true, matchesShortcut: true, isRepeat: false), .toggle)
        for _ in 0..<5 {
            XCTAssertEqual(ToggleHotkeyPolicy.action(isKeyDown: true, matchesShortcut: true, isRepeat: true), .consumeRepeat)
        }
        XCTAssertEqual(ToggleHotkeyPolicy.action(isKeyDown: false, matchesShortcut: true, isRepeat: false), .ignore)
        XCTAssertEqual(ToggleHotkeyPolicy.action(isKeyDown: true, matchesShortcut: true, isRepeat: false), .toggle)
        XCTAssertEqual(ToggleHotkeyPolicy.action(isKeyDown: true, matchesShortcut: false, isRepeat: false), .ignore)
    }
}
