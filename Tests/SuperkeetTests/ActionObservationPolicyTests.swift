import XCTest
@testable import Superkeet

final class ActionObservationPolicyTests: XCTestCase {
    private func spec(_ name: String, risk: ActionToolRisk = .readOnly, server: String = "cua-driver") -> ActionToolSpec {
        ActionToolSpec(descriptor: MCPToolDescriptor(
            serverID: UUID(), serverName: server, name: name, title: nil, description: nil, risk: risk, inputSchemaJSON: "{}"
        ))
    }

    func testCuaDriverObservationsReflectLiveState() {
        for name in ["list_windows", "get_window_state", "list_apps", "get_accessibility_tree", "verify_state",
                     "get_browser_state", "clipboard_read", "zoom"] {
            XCTAssertTrue(ActionObservationPolicy.reflectsLiveState(spec(name)), name)
        }
    }

    func testChromeDevToolsObservationsReflectLiveState() {
        for name in ["list_pages", "take_snapshot", "take_screenshot", "evaluate_script", "list_console_messages"] {
            XCTAssertTrue(ActionObservationPolicy.reflectsLiveState(spec(name, server: "chrome-devtools")), name)
        }
    }

    func testUnknownObservationNamesMatchByPrefixOrFragment() {
        for name in ["list_tabs", "get_focused_element", "take_photo", "verify_title", "window_snapshot", "ScreenShot_region"] {
            XCTAssertTrue(ActionObservationPolicy.reflectsLiveState(spec(name)), name)
        }
    }

    func testMutationsAndStableReadsAreNotObservations() {
        for name in ["click", "type_text", "set_value", "launch_app", "hotkey", "invoke_menu"] {
            XCTAssertFalse(ActionObservationPolicy.reflectsLiveState(spec(name, risk: .mutating)), name)
        }
        // A mutating tool with an observation-like name is still a mutation.
        XCTAssertFalse(ActionObservationPolicy.reflectsLiveState(spec("get_window_state", risk: .mutating)))
        XCTAssertFalse(ActionObservationPolicy.reflectsLiveState(spec("list_windows", risk: .destructive)))
        // Stable read-only lookups may be reused within a run.
        for name in ["search_web", "fetch_url", "read_file", "describe_image", "open_app"] {
            XCTAssertFalse(ActionObservationPolicy.reflectsLiveState(spec(name)), name)
        }
    }

    func testMarkingFlagsOnlyLiveObservationsAndPreservesExistingFlags() {
        var preflagged = spec("search_web")
        preflagged.requiresFreshObservation = true
        let tools = [spec("list_windows"), spec("click", risk: .mutating), spec("search_web"), preflagged]
        let marked = ActionObservationPolicy.markingLiveObservations(tools)
        XCTAssertEqual(marked.map(\.requiresFreshObservation), [true, false, false, true])
        XCTAssertEqual(marked.map(\.toolName), tools.map(\.toolName))
        XCTAssertEqual(marked.map(\.risk), tools.map(\.risk))
    }

    func testOnlyKnownStructuredObservationsAreProjectedForThePlanner() {
        let tools = [spec("get_window_state"), spec("list_windows"), spec("list_apps"), spec("get_accessibility_tree"),
                     spec("take_snapshot", server: "chrome-devtools"), spec("verify_state"), spec("get_window_state", risk: .mutating)]
        let marked = ActionObservationPolicy.markingLiveObservations(tools)
        XCTAssertEqual(marked.map(\.compactObservation), [true, true, true, true, false, false, false])
        XCTAssertTrue(marked.prefix(6).allSatisfy(\.requiresFreshObservation), "Projected observations are also always fresh.")
    }

    func testEveryReadOnlyCuaDriverStateToolIsFreshInRecordedInventory() throws {
        let readOnly = try CuaToolRankingFixture.tools().map { tool -> ActionToolSpec in
            ActionToolSpec(descriptor: MCPToolDescriptor(serverID: tool.serverID, serverName: tool.serverName, name: tool.toolName,
                title: nil, description: tool.description, risk: .readOnly, inputSchemaJSON: "{}"))
        }
        let fresh = Set(ActionObservationPolicy.markingLiveObservations(readOnly).filter(\.requiresFreshObservation).map(\.toolName))
        for required in ["list_apps", "list_windows", "get_window_state", "verify_state", "get_accessibility_tree", "get_browser_state"] {
            XCTAssertTrue(fresh.contains(required), required)
        }
        XCTAssertFalse(fresh.contains("click"))
        XCTAssertFalse(fresh.contains("start_session"))
    }
}
