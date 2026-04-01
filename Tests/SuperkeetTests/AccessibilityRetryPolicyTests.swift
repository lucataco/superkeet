import XCTest
@testable import Superkeet

final class AccessibilityRetryPolicyTests: XCTestCase {

    func testBeginNextAttemptIncrementsUntilLimit() {
        var policy = AccessibilityRetryPolicy(maxAttempts: 3)

        XCTAssertEqual(policy.beginNextAttempt(), 1)
        XCTAssertEqual(policy.beginNextAttempt(), 2)
        XCTAssertEqual(policy.beginNextAttempt(), 3)
        XCTAssertNil(policy.beginNextAttempt())
    }

    func testResetAllowsFreshRetryWindow() {
        var policy = AccessibilityRetryPolicy(maxAttempts: 2)

        XCTAssertEqual(policy.beginNextAttempt(), 1)
        XCTAssertEqual(policy.beginNextAttempt(), 2)
        XCTAssertNil(policy.beginNextAttempt())

        policy.reset()

        XCTAssertEqual(policy.beginNextAttempt(), 1)
    }
}
