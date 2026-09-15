import XCTest
@testable import Superkeet

final class ActionToolFilterTests: XCTestCase {
    private func makeSpec(server: String, name: String) -> ActionToolSpec {
        ActionToolSpec(descriptor: MCPToolDescriptor(
            serverID: UUID(),
            serverName: server,
            name: name,
            title: nil,
            description: "",
            risk: .readOnly,
            inputSchemaJSON: "{}"
        ))
    }

    func testWithholdsChromeDevToolsWhenNonChromeBrowserNamed() {
        let tools = [
            makeSpec(server: "chrome-devtools", name: "new_page"),
            makeSpec(server: "commands", name: "run_process"),
            makeSpec(server: "open-computer-use", name: "get_app_state")
        ]
        let filtered = ActionToolFilter.filtering(tools, task: "Open the Helium browser and go to youtube.com")
        XCTAssertEqual(Set(filtered.map(\.serverName)), ["commands", "open-computer-use"])
        XCTAssertTrue(filtered.contains(where: { $0.toolName == "run_process" }))
    }

    func testKeepsChromeDevToolsWhenChromeNamed() {
        let tools = [
            makeSpec(server: "chrome-devtools", name: "new_page"),
            makeSpec(server: "commands", name: "run_process")
        ]
        let filtered = ActionToolFilter.filtering(tools, task: "Open Chrome and go to youtube.com")
        XCTAssertEqual(filtered.count, 2)
    }

    func testKeepsAllToolsWhenNoBrowserNamed() {
        let tools = [
            makeSpec(server: "chrome-devtools", name: "new_page"),
            makeSpec(server: "commands", name: "run_process")
        ]
        let filtered = ActionToolFilter.filtering(tools, task: "take a screenshot")
        XCTAssertEqual(filtered.count, 2)
    }

    func testFallsBackWhenOnlyChromeToolsExist() {
        let tools = [makeSpec(server: "chrome-devtools", name: "new_page")]
        let filtered = ActionToolFilter.filtering(tools, task: "open helium to youtube")
        XCTAssertEqual(filtered.count, 1)
    }

    func testNamesNonChromeBrowser() {
        XCTAssertTrue(ActionToolFilter.namesNonChromeBrowser("open the helium browser"))
        XCTAssertTrue(ActionToolFilter.namesNonChromeBrowser("go to youtube in Safari"))
        XCTAssertFalse(ActionToolFilter.namesNonChromeBrowser("open google chrome"))
        XCTAssertFalse(ActionToolFilter.namesNonChromeBrowser("take a screenshot"))
    }

    func testIsChromeAutomationMatchesServerName() {
        XCTAssertTrue(ActionToolFilter.isChromeAutomation("chrome-devtools"))
        XCTAssertTrue(ActionToolFilter.isChromeAutomation("Chrome_DevTools"))
        XCTAssertFalse(ActionToolFilter.isChromeAutomation("open-computer-use"))
    }
}
