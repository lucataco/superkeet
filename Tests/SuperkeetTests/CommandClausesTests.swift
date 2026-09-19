import XCTest
@testable import Superkeet

final class CommandClausesTests: XCTestCase {
    func testSplitsOnConjunctionsAndSeparators() {
        XCTAssertEqual(CommandClauses.split("open the notes app and create a new note"), ["open the notes app", "create a new note"])
        XCTAssertEqual(CommandClauses.split("Open Notes, then click Save; quit Safari"), ["Open Notes", "click Save", "quit Safari"])
        XCTAssertEqual(CommandClauses.split("open Helium and then go to youtube.com."), ["open Helium", "go to youtube.com"])
        XCTAssertEqual(CommandClauses.split("Open Discord\nopen Slack"), ["Open Discord", "open Slack"])
    }

    func testSingleClauseAndEmptyInput() {
        XCTAssertEqual(CommandClauses.split("open Discord"), ["open Discord"])
        XCTAssertEqual(CommandClauses.split("   "), [])
        XCTAssertEqual(CommandClauses.split("and"), [])
    }

    func testConjunctionInsideWordsIsNotASeparator() {
        XCTAssertEqual(CommandClauses.split("open Android Studio"), ["open Android Studio"])
        XCTAssertEqual(CommandClauses.split("open Anthem"), ["open Anthem"])
    }

    func testOpenPolicyRequiresAnOpenOrURLClause() {
        for goal in ["open the notes app and create a new note", "launch Discord then click Friends",
                     "create a note and open Notes", "go to youtube.com and search for cats", "Open Notes"] {
            XCTAssertTrue(NativeOpenAction.plansWithoutMCP(goal), goal)
        }
        for goal in ["do the thing", "click Save in Notes", "switch to Notes and type hello", "search for cats",
                     "In the current Chrome tab, go to youtube.com and open Notes"] {
            XCTAssertFalse(NativeOpenAction.plansWithoutMCP(goal), goal)
        }
    }
}
