import XCTest
@testable import Superkeet

final class OverlayElapsedClockTests: XCTestCase {
    func testElapsedIsZeroWhenNotRecording() {
        let start = Date(timeIntervalSince1970: 1_000)
        let now = start.addingTimeInterval(90)
        XCTAssertEqual(OverlayElapsedClock.elapsed(now: now, start: start, isRecording: false), 0)
    }

    func testElapsedIsZeroAtSessionStart() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(OverlayElapsedClock.elapsed(now: start, start: start, isRecording: true), 0)
    }

    func testElapsedAdvancesWhileRecording() {
        let start = Date(timeIntervalSince1970: 1_000)
        let now = start.addingTimeInterval(5)
        XCTAssertEqual(OverlayElapsedClock.elapsed(now: now, start: start, isRecording: true), 5)
    }

    func testNewSessionDoesNotInheritPreviousWallTime() {
        let firstStart = Date(timeIntervalSince1970: 1_000)
        let secondStart = firstStart.addingTimeInterval(90)
        XCTAssertEqual(
            OverlayElapsedClock.elapsed(now: secondStart, start: secondStart, isRecording: true),
            0
        )
        XCTAssertEqual(
            OverlayElapsedClock.elapsed(now: secondStart, start: firstStart, isRecording: true),
            90
        )
    }

    func testNegativeElapsedIsClampedToZero() {
        let start = Date(timeIntervalSince1970: 1_000)
        let now = start.addingTimeInterval(-1)
        XCTAssertEqual(OverlayElapsedClock.elapsed(now: now, start: start, isRecording: true), 0)
    }

    func testFormattedUsesMinutesAndZeroPaddedSeconds() {
        XCTAssertEqual(OverlayElapsedClock.formatted(0), "0:00")
        XCTAssertEqual(OverlayElapsedClock.formatted(5), "0:05")
        XCTAssertEqual(OverlayElapsedClock.formatted(90), "1:30")
    }
}
