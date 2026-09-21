import XCTest
@testable import Superkeet

enum ActiveTabToolFixture {
    static func chrome(serverName: String = "chrome-devtools") -> [ActionToolSpec] {
        let serverID = UUID()
        return ["new_page", "click", "take_snapshot", "navigate_page", "list_pages", "select_page", "evaluate_script"].map { name in
            ActionToolSpec(descriptor: MCPToolDescriptor(serverID: serverID, serverName: serverName, name: name, title: nil,
                description: "Inspect or navigate the current browser page", risk: ["new_page", "click", "navigate_page"].contains(name) ? .mutating : .readOnly,
                inputSchemaJSON: "{}"))
        }
    }
}

final class ActiveTabRoutingTests: XCTestCase {
    func testActiveTabWithholdsOtherBrowserRoutesAndNewTabTools() throws {
        let chrome = ActiveTabToolFixture.chrome()
        let tools = NativeOpenAction.tools + (try CuaToolRankingFixture.tools()) + chrome
        for goal in ["In the active tab, navigate to example.com", "Find DNS records in the current Chrome tab"] {
            let intent = HeuristicIntentExtractor.intent(for: goal)
            let filtered = ActionToolFilter.filtering(tools, intent: intent)
            XCTAssertEqual(Set(filtered.map(\.id)), Set(chrome.filter { $0.toolName != "new_page" }.map(\.id)))
            XCTAssertTrue(filtered.allSatisfy { ActionToolFilter.isChromeAutomation($0.serverName) })
            XCTAssertFalse(filtered.contains { $0.toolName.hasPrefix("browser_") || $0.serverID == NativeOpenAction.serverID })
            let ordered = ActionLimits.prioritizedTools(filtered, intent: intent)
            XCTAssertEqual(ordered.first?.toolName, "list_pages")
            XCTAssertEqual(ordered.dropFirst().first?.toolName, "evaluate_script")
        }
    }

    func testNavigationAndInspectionHaveDifferentNextToolPreferences() {
        let chrome = ActiveTabToolFixture.chrome()
        for (goal, expected) in [("In the active tab, navigate to example.com", "navigate_page"),
                                 ("Find DNS records in the current tab", "take_snapshot")] {
            let intent = HeuristicIntentExtractor.intent(for: goal)
            let filtered = ActionToolFilter.filtering(chrome, intent: intent)
            let ordered = ActionLimits.prioritizedTools(filtered, intent: intent)
            XCTAssertEqual(ordered.dropFirst(2).first?.toolName, expected)
        }
    }

    func testChromeObservationsAreFreshButMutationsRemainCacheable() {
        let filtered = ActionToolFilter.filtering(ActiveTabToolFixture.chrome(), task: "Find DNS in the active tab")
        for spec in filtered {
            XCTAssertEqual(spec.requiresFreshObservation, ["list_pages", "take_snapshot"].contains(spec.toolName))
        }
    }

    func testMissingOrAmbiguousChromeNeverFallsBackToCuaOrNativeOpen() throws {
        let intent = HeuristicIntentExtractor.intent(for: "Find DNS in the active tab")
        let other = NativeOpenAction.tools + (try CuaToolRankingFixture.tools())
        XCTAssertTrue(ActionToolFilter.filtering(other, intent: intent).isEmpty)
        let ambiguous = other + ActiveTabToolFixture.chrome() + ActiveTabToolFixture.chrome(serverName: "chrome-devtools-work")
        XCTAssertTrue(ActionToolFilter.filtering(ambiguous, intent: intent).isEmpty)
    }

    func testExplicitSafariTabDoesNotSilentlyBecomeChrome() throws {
        let tools = ActiveTabToolFixture.chrome() + (try CuaToolRankingFixture.tools())
        XCTAssertTrue(ActionToolFilter.filtering(tools, task: "Find DNS in the current Safari tab").isEmpty)
    }

    func testIncompleteChromeToolSetCannotInventPageDiscovery() {
        let chrome = ActiveTabToolFixture.chrome()
        XCTAssertTrue(ActionToolFilter.filtering(chrome.filter { $0.toolName != "list_pages" }, task: "Find DNS in the active tab").isEmpty)
        XCTAssertTrue(ActionToolFilter.filtering(chrome.filter { $0.toolName != "navigate_page" }, task: "Open example.com in the active tab").isEmpty)
        XCTAssertTrue(ActionToolFilter.filtering(chrome.filter { $0.toolName != "take_snapshot" }, task: "Find DNS in the active tab").isEmpty)
    }

    func testUnscopedOpenKeepsExistingRouting() throws {
        let tools = NativeOpenAction.tools + ActiveTabToolFixture.chrome() + (try CuaToolRankingFixture.tools())
        let useful = tools.filter { !ActionToolFilter.housekeepingNames.contains($0.toolName) }
        XCTAssertEqual(ActionToolFilter.filtering(tools, task: "Open Chrome and go to example.com"), useful)
        XCTAssertLessThan(useful.count, tools.count, "Cua Driver's housekeeping tools are withheld from every plan.")
    }
}
