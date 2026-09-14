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

    func testRepeatedShortLivedSuccessfulStartsStillHitRestartLimit() {
        var policy = AutoRestartPolicy()
        let now = Date()
        for (offset, delay) in [(0.0, 2.0), (10.0, 4.0), (20.0, 8.0)] {
            policy.recordReady(now: now.addingTimeInterval(offset))
            XCTAssertEqual(policy.nextDelay(now: now.addingTimeInterval(offset + 1)), delay)
        }
        policy.recordReady(now: now.addingTimeInterval(30))
        XCTAssertNil(policy.nextDelay(now: now.addingTimeInterval(31)))
    }

    func testSustainedHealthyRunResetsBackoff() {
        var policy = AutoRestartPolicy(window: 60)
        let now = Date()
        _ = policy.nextDelay(now: now)
        _ = policy.nextDelay(now: now.addingTimeInterval(1))
        policy.recordReady(now: now.addingTimeInterval(2))
        XCTAssertEqual(policy.nextDelay(now: now.addingTimeInterval(62)), 2)
        XCTAssertEqual(policy.attemptTimestamps.count, 1)
    }
}
