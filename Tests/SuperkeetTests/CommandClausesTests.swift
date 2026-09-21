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
                     "create a note and open Notes", "go to youtube.com and search for cats", "Open Notes",
                     "switch to Notes and type hello", "search for cats", "Lets open Chrome and search for Morgan Freeman"] {
            XCTAssertTrue(NativeOpenAction.plansWithoutMCP(goal), goal)
        }
        for goal in ["do the thing", "click Save in Notes", "In the current Chrome tab, go to youtube.com and open Notes"] {
            XCTAssertFalse(NativeOpenAction.plansWithoutMCP(goal), goal)
        }
    }

    func testAndOnlySplitsWhenANewInstructionFollows() {
        XCTAssertEqual(CommandClauses.split("search for Morgan Freeman and Tom Hanks"), ["search for Morgan Freeman and Tom Hanks"])
        XCTAssertEqual(CommandClauses.split("open Notes and Reminders"), ["open Notes and Reminders"])
        XCTAssertEqual(CommandClauses.split("type milk, eggs and bread into Body"), ["type milk, eggs and bread into Body"])
        XCTAssertEqual(CommandClauses.split("Lets open Chrome and search for Morgan Freeman"), ["Lets open Chrome", "search for Morgan Freeman"])
        XCTAssertEqual(CommandClauses.split("open Chrome and then Tom Hanks"), ["open Chrome", "Tom Hanks"], "\"then\" always sequences.")
        XCTAssertEqual(CommandClauses.split("open Chrome; Tom Hanks"), ["open Chrome", "Tom Hanks"])
        XCTAssertEqual(CommandClauses.split("open Chrome and youtube.com"), ["open Chrome", "youtube.com"], "A web address starts a step.")
        XCTAssertEqual(CommandClauses.split("open Notes and please save it"), ["open Notes", "please save it"], "Lead-ins before the verb are fine.")
        XCTAssertFalse(CommandClauses.hasSequence("search for cats and dogs"))
        XCTAssertTrue(CommandClauses.hasSequence("search for cats and open Notes"))
        XCTAssertTrue(CommandClauses.hasSequence("open Notes then Reminders"))
    }
}
