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

    func testAutoApproveRequiresApprovalOnlyForDestructiveTools() {
        XCTAssertFalse(ActionApprovalPolicy.autoApprove.requiresApproval(for: .readOnly))
        XCTAssertFalse(ActionApprovalPolicy.autoApprove.requiresApproval(for: .mutating))
        XCTAssertTrue(ActionApprovalPolicy.autoApprove.requiresApproval(for: .destructive))
    }

    func testToolSpecsDefaultToRiskBasedApprovalUnderEveryPolicy() {
        for risk in ActionToolRisk.allCases {
            let spec = tool(risk: risk)
            XCTAssertFalse(spec.approvalExempt)
            for policy in ActionApprovalPolicy.allCases {
                XCTAssertEqual(policy.requiresApproval(for: spec), policy.requiresApproval(for: risk), "\(policy), \(risk)")
            }
        }
    }

    func testToolExemptionSkipsDefaultApprovalButNeverOverridesAlwaysAsk() {
        var spec = tool(risk: .mutating)
        spec.approvalExempt = true
        XCTAssertFalse(ActionApprovalPolicy.readOnlyAuto.requiresApproval(for: spec))
        XCTAssertTrue(ActionApprovalPolicy.alwaysAsk.requiresApproval(for: spec))
        XCTAssertFalse(ActionApprovalPolicy.autoApprove.requiresApproval(for: spec))
    }

    func testAutoApproveStillAsksForDestructiveToolsWithAnExemption() {
        var spec = tool(risk: .destructive)
        spec.approvalExempt = true
        XCTAssertTrue(ActionApprovalPolicy.autoApprove.requiresApproval(for: spec))
    }

    func testNativeOpensAreExemptUnderTheDefaultPolicyButShortcutsStillAsk() throws {
        for (name, exempt) in [("open_app", true), ("open_url", true), ("press_shortcut", false)] {
            let spec = try XCTUnwrap(NativeOpenAction.tools.first { $0.toolName == name })
            XCTAssertEqual(spec.approvalExempt, exempt, name)
            XCTAssertEqual(spec.risk, .mutating, "\(name) must still be treated as a state change.")
            XCTAssertEqual(ActionApprovalPolicy.readOnlyAuto.requiresApproval(for: spec), !exempt, name)
            XCTAssertTrue(ActionApprovalPolicy.alwaysAsk.requiresApproval(for: spec), name)
            XCTAssertFalse(ActionApprovalPolicy.autoApprove.requiresApproval(for: spec), name)
        }
    }

    func testPoliciesAreOrderedFromLeastToMostPermissiveWithStableRawValues() {
        XCTAssertEqual(ActionApprovalPolicy.allCases, [.alwaysAsk, .readOnlyAuto, .autoApprove])
        XCTAssertEqual(ActionApprovalPolicy.allCases.map(\.rawValue), ["alwaysAsk", "readOnlyAuto", "autoApprove"])
    }

    func testPolicyRawValuesRoundTrip() {
        for policy in ActionApprovalPolicy.allCases {
            XCTAssertEqual(ActionApprovalPolicy(rawValue: policy.rawValue), policy)
        }
    }

    func testMenuBarAutoApproveToggleRoundTripsTheUsersAskingPolicy() {
        for asking in [ActionApprovalPolicy.alwaysAsk, .readOnlyAuto] {
            let on = ActionApprovalPolicy.togglingAutoApprove(current: asking, remembered: nil)
            XCTAssertEqual(on.policy, .autoApprove)
            XCTAssertEqual(on.remembered, asking)

            let off = ActionApprovalPolicy.togglingAutoApprove(current: on.policy, remembered: on.remembered)
            XCTAssertEqual(off.policy, asking, "turning auto-approve off must restore \(asking)")
            XCTAssertNil(off.remembered)
        }
    }

    func testMenuBarAutoApproveToggleFallsBackToTheDefaultWithoutAMemory() {
        // Auto-approve was chosen in Settings, so there is nothing to restore; use the default.
        let off = ActionApprovalPolicy.togglingAutoApprove(current: .autoApprove, remembered: nil)
        XCTAssertEqual(off.policy, .readOnlyAuto)
        // A corrupt memory of "autoApprove" must not leave the checkbox stuck on.
        let stuck = ActionApprovalPolicy.togglingAutoApprove(current: .autoApprove, remembered: .autoApprove)
        XCTAssertEqual(stuck.policy, .readOnlyAuto)
    }

    private func tool(risk: ActionToolRisk) -> ActionToolSpec {
        ActionToolSpec(descriptor: MCPToolDescriptor(serverID: UUID(), serverName: "fixture", name: "tool",
            title: nil, description: nil, risk: risk, inputSchemaJSON: "{}"))
    }
}
