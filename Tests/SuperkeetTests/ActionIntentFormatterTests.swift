import XCTest
@testable import Superkeet

final class ActionIntentFormatterTests: XCTestCase {
    func testCommandLineIntent() {
        let summary = ActionIntentFormatter.summary(
            toolName: "run_process",
            argumentsJSON: #"{"command_line":"open -a Helium"}"#
        )
        XCTAssertEqual(summary, "Run: open -a Helium")
    }

    func testArgvIntent() {
        let summary = ActionIntentFormatter.summary(
            toolName: "run_process",
            argumentsJSON: #"{"argv":["open","-a","Helium"]}"#
        )
        XCTAssertEqual(summary, "Run: open -a Helium")
    }

    func testClickIntent() {
        let summary = ActionIntentFormatter.summary(
            toolName: "click",
            argumentsJSON: #"{"app":"Helium","element_index":"7"}"#
        )
        XCTAssertEqual(summary, "Click element 7 in Helium")
    }

    func testTypeIntent() {
        let summary = ActionIntentFormatter.summary(
            toolName: "type_text",
            argumentsJSON: #"{"app":"Helium","text":"https://duckduckgo.com"}"#
        )
        XCTAssertEqual(summary, "Type “https://duckduckgo.com” in Helium")
    }

    func testWebSearchURLReadsAsASearch() {
        XCTAssertEqual(
            ActionIntentFormatter.summary(toolName: "open_url", argumentsJSON: #"{"url":"https://www.google.com/search?q=Morgan%20Freeman","browser":"chrome"}"#),
            "Search the web for “Morgan Freeman” in chrome"
        )
        XCTAssertEqual(
            ActionIntentFormatter.summary(toolName: "open_url", argumentsJSON: #"{"url":"https://www.google.com/search?q=cats"}"#),
            "Search the web for “cats”"
        )
    }

    func testOpenURLIntent() {
        let summary = ActionIntentFormatter.summary(
            toolName: "navigate_page",
            argumentsJSON: #"{"url":"https://example.com"}"#
        )
        XCTAssertEqual(summary, "Open https://example.com")
    }

    func testNativeOpenApprovalShowsAppAndNamedBrowser() {
        XCTAssertEqual(ActionIntentFormatter.summary(toolName: "open_app", argumentsJSON: #"{"name":"Discord"}"#), "Open Discord")
        XCTAssertEqual(ActionIntentFormatter.summary(toolName: "open_url", argumentsJSON: #"{"url":"https://youtube.com","browser":"Helium"}"#),
                       "Open https://youtube.com in Helium")
        XCTAssertEqual(ActionIntentFormatter.summary(toolName: "press_shortcut", argumentsJSON: #"{"app":"Notes","keys":["cmd","n"]}"#),
                       "Press ⌘N in Notes")
        XCTAssertEqual(ActionIntentFormatter.summary(toolName: "press_shortcut", argumentsJSON: #"{"keys":["cmd","hyper"]}"#),
                       "Press cmd+hyper", "Unsupported chords are still described rather than hidden.")
    }

    func testUnknownToolReturnsNil() {
        XCTAssertNil(ActionIntentFormatter.summary(toolName: "mystery", argumentsJSON: "{}"))
    }

    func testLongTextIsClipped() {
        let longText = String(repeating: "a", count: 300)
        let summary = ActionIntentFormatter.summary(
            toolName: "type_text",
            argumentsJSON: #"{"text":"\#(longText)"}"#
        )
        XCTAssertNotNil(summary)
        XCTAssertLessThanOrEqual((summary ?? "").count, ActionIntentFormatter.maximumLength + 1)
        XCTAssertTrue((summary ?? "").hasSuffix("…"))
    }
}
