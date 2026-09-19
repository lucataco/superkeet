import XCTest
@testable import Superkeet

final class ActionProgressSummaryTests: XCTestCase {
    func testEmptySummaryProducesNoInstructions() {
        let summary = ActionProgressSummary()
        XCTAssertTrue(summary.isEmpty)
        XCTAssertEqual(summary.instructions(), "")
    }

    func testEntriesAreListedInOrderWithOutcomeMarks() {
        var summary = ActionProgressSummary()
        summary.record(toolName: "list_windows", argumentsJSON: #"{"on_screen_only":true}"#, result: "pid 91 window 651 \"Notes\"")
        summary.recordFailure(toolName: "click", argumentsJSON: #"{"element_token":"s1:9"}"#, message: "The action was not approved")
        summary.record(toolName: "press_shortcut", argumentsJSON: #"{"app":"Notes","keys":["cmd","n"]}"#, result: "Pressed ⌘N in Notes (pid 91).")
        let text = summary.instructions()
        XCTAssertTrue(text.hasPrefix("Your earlier work on this step ran out of room and was condensed."))
        XCTAssertTrue(text.contains("do not repeat them"))
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[1], #"✓ list_windows({"on_screen_only":true}) → pid 91 window 651 "Notes""#)
        XCTAssertEqual(lines[2], #"✗ click({"element_token":"s1:9"}) → The action was not approved"#)
        XCTAssertEqual(lines[3], #"✓ press_shortcut({"app":"Notes","keys":["cmd","n"]}) → Pressed ⌘N in Notes (pid 91)."#)
    }

    func testArgumentsAndResultsAreClippedAndFlattened() {
        var summary = ActionProgressSummary()
        summary.record(toolName: "get_window_state", argumentsJSON: String(repeating: "a", count: 500),
                       result: "line one\n  line two\n" + String(repeating: "r", count: 500))
        let line = summary.instructions().split(separator: "\n").last.map(String.init) ?? ""
        XCTAssertFalse(line.contains("\n"))
        XCTAssertTrue(line.contains("line one line two"))
        XCTAssertLessThan(line.count, ActionProgressSummary.argumentLimit + ActionProgressSummary.resultLimit + 40)
        XCTAssertTrue(line.contains("…"))
    }

    func testOldestEntriesAreCollapsedToFitTheLimit() {
        var summary = ActionProgressSummary()
        for index in 0..<40 {
            summary.record(toolName: "step\(index)", argumentsJSON: "{}", result: String(repeating: "x", count: 100))
        }
        let text = summary.instructions(limit: 800)
        XCTAssertLessThanOrEqual(text.count, 800)
        XCTAssertTrue(text.contains("earlier calls omitted"))
        XCTAssertTrue(text.contains("step39"), "The newest call describes the current state and is always kept.")
        XCTAssertFalse(text.contains("step0("))
    }

    func testASingleOversizedEntryIsStillReported() {
        var summary = ActionProgressSummary()
        summary.record(toolName: "only", argumentsJSON: "{}", result: String(repeating: "y", count: 150))
        let text = summary.instructions(limit: 50)
        XCTAssertTrue(text.contains("only({})"), "At least one entry survives even when the limit is tiny.")
    }
}
