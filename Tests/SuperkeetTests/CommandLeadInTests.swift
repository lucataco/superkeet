import XCTest
@testable import Superkeet

final class CommandLeadInTests: XCTestCase {
    func testStripsSpokenLeadInsAndKeepsTheCommandCasing() {
        XCTAssertEqual(CommandLeadIn.strip("Lets open Chrome"), "open Chrome")
        XCTAssertEqual(CommandLeadIn.strip("Let's open Chrome"), "open Chrome")
        XCTAssertEqual(CommandLeadIn.strip("Let’s open Chrome"), "open Chrome")
        XCTAssertEqual(CommandLeadIn.strip("Hey Superkeet, please open the Notes app"), "open the Notes app")
        XCTAssertEqual(CommandLeadIn.strip("um, can you launch Discord"), "launch Discord")
        XCTAssertEqual(CommandLeadIn.strip("I want to open Chrome"), "open Chrome")
        XCTAssertEqual(CommandLeadIn.strip("I'd like to search for cats"), "search for cats")
        XCTAssertEqual(CommandLeadIn.strip("Okay so go ahead and pull up Notes"), "pull up Notes")
        XCTAssertEqual(CommandLeadIn.strip("  yeah, just open Notes  "), "open Notes")
    }

    func testLeavesCommandsWithoutLeadInsAlone() {
        XCTAssertEqual(CommandLeadIn.strip("open Chrome"), "open Chrome")
        XCTAssertEqual(CommandLeadIn.strip("hide the window"), "hide the window", "\"hi\" inside \"hide\" is not a lead-in.")
        XCTAssertEqual(CommandLeadIn.strip("sold out"), "sold out", "\"so\" inside \"sold\" is not a lead-in.")
        XCTAssertEqual(CommandLeadIn.strip("Notes open and"), "Notes open and")
        XCTAssertEqual(CommandLeadIn.strip(""), "")
        XCTAssertEqual(CommandLeadIn.strip("please"), "", "A lead-in with nothing after it leaves nothing.")
    }

    func testIntentExtractorAndDetectorAgreeOnWhereTheVerbStarts() {
        for phrase in ["Lets open Chrome", "please open Chrome", "I want to open Chrome", "Okay, can you open Chrome"] {
            let intent = HeuristicIntentExtractor.intent(for: phrase)
            XCTAssertEqual(intent.action, .openApp, phrase)
            XCTAssertEqual(intent.goal, "open Chrome", phrase)
            XCTAssertEqual(SpeculativeIntentDetector.leadingClause(in: phrase)?.candidate, "chrome", phrase)
        }
    }
}
