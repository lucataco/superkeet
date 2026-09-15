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

    func testOpenURLIntent() {
        let summary = ActionIntentFormatter.summary(
            toolName: "navigate_page",
            argumentsJSON: #"{"url":"https://example.com"}"#
        )
        XCTAssertEqual(summary, "Open https://example.com")
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
