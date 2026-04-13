import XCTest
@testable import Superkeet

final class ParakeetServiceTests: XCTestCase {

    func testShouldScheduleIdleShutdownOnlyWhenIdleAndTimeoutEnabled() {
        XCTAssertTrue(ParakeetService.shouldScheduleIdleShutdown(timeoutMinutes: 5, state: .idle))
        XCTAssertFalse(ParakeetService.shouldScheduleIdleShutdown(timeoutMinutes: 0, state: .idle))
        XCTAssertFalse(ParakeetService.shouldScheduleIdleShutdown(timeoutMinutes: 5, state: .recording))
        XCTAssertFalse(ParakeetService.shouldScheduleIdleShutdown(timeoutMinutes: 5, state: .starting))
        XCTAssertFalse(ParakeetService.shouldScheduleIdleShutdown(timeoutMinutes: 5, state: .stopped))
    }
}
