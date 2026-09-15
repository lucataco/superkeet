import XCTest
@testable import Superkeet

final class ActionApprovalPolicyTests: XCTestCase {
    func testAlwaysAskRequiresApprovalForEveryRisk() {
        for risk in ActionToolRisk.allCases {
            XCTAssertTrue(ActionApprovalPolicy.alwaysAsk.requiresApproval(for: risk))
        }
    }

    func testReadOnlyAutoSkipsApprovalOnlyForReadOnlyTools() {
        XCTAssertFalse(ActionApprovalPolicy.readOnlyAuto.requiresApproval(for: .readOnly))
        XCTAssertTrue(ActionApprovalPolicy.readOnlyAuto.requiresApproval(for: .mutating))
        XCTAssertTrue(ActionApprovalPolicy.readOnlyAuto.requiresApproval(for: .destructive))
    }

    func testPolicyRawValuesRoundTrip() {
        for policy in ActionApprovalPolicy.allCases {
            XCTAssertEqual(ActionApprovalPolicy(rawValue: policy.rawValue), policy)
        }
    }
}
