import XCTest
@testable import Superkeet

final class MCPToolRiskClassifierTests: XCTestCase {
    func testReadOnlyHintWins() {
        let annotations = MCPToolAnnotations(readOnlyHint: true, destructiveHint: true)
        XCTAssertEqual(MCPToolRiskClassifier.risk(for: annotations), .readOnly)
    }

    func testDestructiveHint() {
        XCTAssertEqual(
            MCPToolRiskClassifier.risk(for: MCPToolAnnotations(destructiveHint: true)),
            .destructive
        )
    }

    func testDefaultsToMutating() {
        XCTAssertEqual(MCPToolRiskClassifier.risk(for: MCPToolAnnotations()), .mutating)
        XCTAssertEqual(
            MCPToolRiskClassifier.risk(for: MCPToolAnnotations(readOnlyHint: false, destructiveHint: false)),
            .mutating
        )
    }

    func testObservationNamesWithoutHintsAreReadOnly() {
        XCTAssertEqual(MCPToolRiskClassifier.risk(for: MCPToolAnnotations(), name: "list_apps"), .readOnly)
        XCTAssertEqual(MCPToolRiskClassifier.risk(for: MCPToolAnnotations(), name: "get_app_state"), .readOnly)
        XCTAssertEqual(MCPToolRiskClassifier.risk(for: MCPToolAnnotations(), name: "take_snapshot"), .readOnly)
        XCTAssertEqual(MCPToolRiskClassifier.risk(for: MCPToolAnnotations(), name: "list_pages"), .readOnly)
    }

    func testActionNamesWithoutHintsStayMutating() {
        XCTAssertEqual(MCPToolRiskClassifier.risk(for: MCPToolAnnotations(), name: "run_process"), .mutating)
        XCTAssertEqual(MCPToolRiskClassifier.risk(for: MCPToolAnnotations(), name: "click"), .mutating)
        XCTAssertEqual(MCPToolRiskClassifier.risk(for: MCPToolAnnotations(), name: "type_text"), .mutating)
    }

    func testExplicitMutatingHintOverridesObservationName() {
        XCTAssertEqual(
            MCPToolRiskClassifier.risk(for: MCPToolAnnotations(readOnlyHint: false), name: "list_apps"),
            .mutating
        )
    }

    func testExplicitDestructiveHintOverridesObservationName() {
        XCTAssertEqual(
            MCPToolRiskClassifier.risk(for: MCPToolAnnotations(destructiveHint: true), name: "get_state"),
            .destructive
        )
    }
}
