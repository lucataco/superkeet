import XCTest
@testable import Superkeet

/// Spoken commands arrive punctuated and wrapped in filler. These tests pin down how sentence
/// ends, acknowledgements, and trailing politeness are kept out of arguments and steps.
final class CommandFillerTests: XCTestCase {
    func testSentencesSplitIntoSteps() {
        XCTAssertEqual(CommandClauses.split("Open Discord. Open Notes. Open Helium."), ["Open Discord", "Open Notes", "Open Helium"])
        XCTAssertEqual(
            CommandClauses.split("Can you open up the Notes app for me? And once you're there, can you create a new note?"),
            ["Can you open up the Notes app for me", "can you create a new note"]
        )
        XCTAssertEqual(CommandClauses.split("open notes. Ah."), ["open notes"])
        XCTAssertEqual(CommandClauses.split("search for Morgan Freeman. And also"), ["search for Morgan Freeman"])
        XCTAssertEqual(CommandClauses.split("Discord. Open notes. Open healing."), ["Discord", "Open notes", "Open healing"])
    }

    func testAbbreviationsAndDomainsSurviveSentenceSplitting() {
        XCTAssertEqual(CommandClauses.split("search for Dr. Smith"), ["search for Dr. Smith"])
        XCTAssertEqual(CommandClauses.split("go to youtube.com"), ["go to youtube.com"])
        XCTAssertEqual(CommandClauses.split("open Helium and then go to youtube.com."), ["open Helium", "go to youtube.com"])
        XCTAssertEqual(CommandClauses.split("type 3.5 into the field"), ["type 3.5 into the field"])
    }

    func testAcknowledgementsAreNotCommands() {
        for text in ["Great. Great. Okay. Let's move on.", "Cool. Awesome. Thank you.", "Nice, nice. Okay.", "okay",
                     "That works, thanks", "never mind", "  "] {
            XCTAssertTrue(CommandLeadIn.isAcknowledgement(text), text)
        }
        for text in ["open Notes", "Okay, open Notes", "great, now search for cats", "thanks, quit Safari", "stop"] {
            XCTAssertFalse(CommandLeadIn.isAcknowledgement(text), text)
        }
    }

    func testAcknowledgementsAreIgnoredInCommandMode() {
        let event = TranscriptEvent(type: "complete", sessionID: "t", text: "Great. Great. Okay, let's move on.", status: "ok")
        XCTAssertEqual(CommandTranscriptDelivery.decide(event: event, commandMode: true, replacements: [], bundleID: ""), .ignored)
        let command = TranscriptEvent(type: "complete", sessionID: "t", text: "Okay, open Notes.", status: "ok")
        XCTAssertEqual(CommandTranscriptDelivery.decide(event: command, commandMode: true, replacements: [], bundleID: ""), .command("Okay, open Notes."))
        XCTAssertEqual(TranscriptOutcome.ignored.label, "Nothing to do")
        XCTAssertEqual(TranscriptOutcome.ignored.severity, .neutral)
    }

    func testTrailingFillerLeavesArguments() {
        XCTAssertEqual(CommandLeadIn.stripTrailing("open Notes for me, please."), "open Notes")
        XCTAssertEqual(CommandLeadIn.stripTrailing("the Notes app for me?"), "the Notes app")
        XCTAssertEqual(CommandLeadIn.stripTrailing("notes. Ah."), "notes")
        XCTAssertEqual(CommandLeadIn.stripTrailing("Morgan Freeman"), "Morgan Freeman")
        XCTAssertEqual(CommandLeadIn.stripTrailing("please"), "please", "Nothing before the filler; the lead-in strip owns that case.")
        XCTAssertEqual(CommandLeadIn.trim("Okay so can you open the Notes app for me please"), "open the Notes app")
    }

    func testTrailingFillerIsRemovedFromAppNamesAndQueries() {
        XCTAssertEqual(HeuristicIntentExtractor.intent(for: "can you open up the Notes app for me?").app, "the Notes app")
        XCTAssertEqual(HeuristicIntentExtractor.intent(for: "open notes. Ah.").app, "notes")
        XCTAssertEqual(HeuristicIntentExtractor.intent(for: "search for cats please").query, "cats")
        XCTAssertEqual(NativeOpenAction.fastPath(for: HeuristicIntentExtractor.intent(for: "open notes. Ah.")), .openApp(name: "notes"))
        XCTAssertEqual(
            NativeOpenAction.fastPath(for: HeuristicIntentExtractor.intent(for: "please open up the Notes app for me")),
            .openApp(name: "the Notes app")
        )
        XCTAssertEqual(SpeculativeIntentDetector.leadingClause(in: "open the notes app for me")?.candidate, "the notes app")
    }

    func testTypedTextKeepsItsWords() {
        XCTAssertEqual(HeuristicIntentExtractor.intent(for: "type okay").text, "okay")
        XCTAssertEqual(HeuristicIntentExtractor.intent(for: "type thank you for the update").text, "thank you for the update")
    }

    func testGoogleSearchPhrasings() {
        for phrase in ["can you Google search Norbert Wiener?", "google search for Norbert Wiener", "search google for Norbert Wiener",
                       "search up Norbert Wiener", "Google Norbert Wiener", "look up Norbert Wiener"] {
            let intent = HeuristicIntentExtractor.intent(for: phrase)
            XCTAssertEqual(intent.action, .webSearch, phrase)
            XCTAssertEqual(intent.query, "Norbert Wiener", phrase)
        }
        XCTAssertEqual(HeuristicIntentExtractor.intent(for: "Google search Norbert Wiener in Arc").browser, "arc")
    }

    func testContextClausesAreDropped() {
        for clause in ["inside this new note", "once you're there", "in the Notes app", "and from there", "and", "okay so"] {
            XCTAssertTrue(CommandClauses.isDroppable(clause), clause)
        }
        for clause in ["on the second line write hello", "in Chrome search for cats", "open Notes", "Tom Hanks"] {
            XCTAssertFalse(CommandClauses.isDroppable(clause), clause)
        }
        XCTAssertEqual(
            CommandClauses.split("open Notes and create a new note and inside this new note, let's make the title say hello"),
            ["open Notes", "create a new note", "let's make the title say hello"]
        )
        XCTAssertEqual(CommandClauses.split("search for Morgan Freeman and Tom Hanks"), ["search for Morgan Freeman and Tom Hanks"])
    }

    func testLeadInsIncludeClauseConnectors() {
        XCTAssertEqual(CommandLeadIn.strip("And once you're there, can you create a new note?"), "create a new note?")
        XCTAssertEqual(CommandLeadIn.strip("and then open Notes"), "open Notes")
        XCTAssertEqual(CommandLeadIn.strip("Notes open and"), "Notes open and")
        XCTAssertEqual(HeuristicIntentExtractor.intent(for: "And once you're there, can you create a new note?").goal, "create a new note?")
    }
}
