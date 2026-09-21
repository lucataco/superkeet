import XCTest
@testable import Superkeet

final class InteractionRiskTests: XCTestCase {
    func testDestructiveHintOnPlainInteractionsMeansChangesState() {
        // Cua Driver annotates click as destructive; under Just Do It that would raise a card for
        // every click. Interactions change state but delete nothing.
        for name in ["click", "double_click", "right_click", "type_text", "press_key", "hotkey", "scroll", "drag", "set_value"] {
            XCTAssertEqual(MCPToolRiskClassifier.risk(for: MCPToolAnnotations(destructiveHint: true), name: name), .mutating, name)
            XCTAssertFalse(ActionApprovalPolicy.autoApprove.requiresApproval(for: .mutating), name)
            XCTAssertTrue(ActionApprovalPolicy.readOnlyAuto.requiresApproval(for: .mutating), name)
        }
    }

    func testDestructiveHintStillWinsForRealDeletions() {
        for name in ["kill_app", "delete_file", "close_window", "run_process", ""] {
            XCTAssertEqual(MCPToolRiskClassifier.risk(for: MCPToolAnnotations(destructiveHint: true), name: name), .destructive, name)
        }
    }

    func testReadOnlyHintStillWinsOverInteractionNames() {
        XCTAssertEqual(MCPToolRiskClassifier.risk(for: MCPToolAnnotations(readOnlyHint: true, destructiveHint: true), name: "click"), .readOnly)
    }
}
