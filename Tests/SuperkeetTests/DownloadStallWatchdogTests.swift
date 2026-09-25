import XCTest
@testable import Superkeet

final class DownloadStallWatchdogTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testNotStalledBeforeTimeout() {
        let watchdog = DownloadStallWatchdog(stallTimeout: 60, now: start)
        XCTAssertFalse(watchdog.checkForStall(at: start.addingTimeInterval(59)))
        XCTAssertFalse(watchdog.didStall)
    }

    func testStallsOnceAfterTimeoutWithoutActivity() {
        let watchdog = DownloadStallWatchdog(stallTimeout: 60, now: start)
        XCTAssertTrue(watchdog.checkForStall(at: start.addingTimeInterval(60)))
        XCTAssertTrue(watchdog.didStall)
        XCTAssertFalse(watchdog.checkForStall(at: start.addingTimeInterval(120)), "Reports the stall only once")
    }

    func testActivityResetsTheTimer() {
        let watchdog = DownloadStallWatchdog(stallTimeout: 60, now: start)
        watchdog.recordActivity(at: start.addingTimeInterval(50))
        XCTAssertFalse(watchdog.checkForStall(at: start.addingTimeInterval(100)))
        XCTAssertTrue(watchdog.checkForStall(at: start.addingTimeInterval(110)))
    }

    func testStallMessageMentionsTimeout() {
        let watchdog = DownloadStallWatchdog(stallTimeout: 90, now: start)
        XCTAssertTrue(watchdog.stallMessage.contains("90 seconds"))
    }
}
