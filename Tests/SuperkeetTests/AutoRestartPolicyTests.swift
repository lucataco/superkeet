import XCTest
@testable import Superkeet

final class AutoRestartPolicyTests: XCTestCase {

    func testBackoffGrowsUntilMaxAttempts() {
        var policy = AutoRestartPolicy(maxAttempts: 3, window: 60, baseDelay: 2, maxDelay: 30)
        let now = Date()

        XCTAssertEqual(policy.nextDelay(now: now), 2)
        XCTAssertEqual(policy.nextDelay(now: now.addingTimeInterval(1)), 4)
        XCTAssertEqual(policy.nextDelay(now: now.addingTimeInterval(2)), 8)
        XCTAssertNil(policy.nextDelay(now: now.addingTimeInterval(3)))
    }

    func testAttemptsExpireOutsideWindow() {
        var policy = AutoRestartPolicy(maxAttempts: 2, window: 5, baseDelay: 2, maxDelay: 30)
        let now = Date()

        XCTAssertEqual(policy.nextDelay(now: now), 2)
        XCTAssertEqual(policy.nextDelay(now: now.addingTimeInterval(1)), 4)
        XCTAssertNil(policy.nextDelay(now: now.addingTimeInterval(2)))
        XCTAssertEqual(policy.nextDelay(now: now.addingTimeInterval(7)), 2)
    }

    func testResetClearsBackoffState() {
        var policy = AutoRestartPolicy(maxAttempts: 2, window: 60, baseDelay: 2, maxDelay: 30)
        let now = Date()

        XCTAssertEqual(policy.nextDelay(now: now), 2)
        XCTAssertEqual(policy.nextDelay(now: now.addingTimeInterval(1)), 4)
        policy.reset()
        XCTAssertEqual(policy.nextDelay(now: now.addingTimeInterval(2)), 2)
    }
}
