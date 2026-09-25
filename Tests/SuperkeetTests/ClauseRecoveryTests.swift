import XCTest
@testable import Superkeet

/// Splitting and routing survive the recogniser's glitches and conversational phrasing.
final class ClauseRecoveryTests: XCTestCase {
    private let notes = URL(fileURLWithPath: "/fixture/Applications/Notes.app")

    private func context(currentApp: String? = "Notes") -> NativeClauseContext {
        NativeClauseContext(
            currentApp: currentApp,
            resolveApp: { [notes] in AppResolver.normalizedName($0).contains("note") ? notes : nil },
            isRunning: { _ in true }
        )
    }

    func testRequestAfterGarbledWordsStartsANewClause() {
        XCTAssertEqual(
            CommandClauses.split("can you open up the notes app for me and umce right there can you create a new note"),
            ["can you open up the notes app for me", "umce right there can you create a new note"]
        )
        XCTAssertEqual(
            CommandClauses.split("create a new note and inside this new note let's make the title say hello"),
            ["create a new note", "inside this new note let's make the title say hello"]
        )
    }

    func testOrdinaryConjunctionsStillStayTogether() {
        XCTAssertEqual(CommandClauses.split("search for Morgan Freeman and Tom Hanks"), ["search for Morgan Freeman and Tom Hanks"])
        XCTAssertEqual(CommandClauses.split("type salt and pepper"), ["type salt and pepper"])
        XCTAssertNil(CommandClauses.requestSuffix("can you create a new note"), "A marker with nothing before it is handled by lead-in stripping.")
        XCTAssertNil(CommandClauses.requestSuffix("one two three four five can you open Notes"), "Only a few words may precede the request.")
    }

    func testRouterReadsThroughLeadInsAndGarbledPrefixes() throws {
        let commandN = try XCTUnwrap(KeyboardShortcut(keys: ["cmd", "n"]))
        for clause in ["can you create a new note", "once you're there can you create a new note", "umce right there can you create a new note"] {
            XCTAssertEqual(NativeClauseRouter.action(for: clause, context: context()), .pressShortcut(app: "Notes", shortcut: commandN), clause)
        }
        XCTAssertEqual(
            NativeClauseRouter.action(for: "inside this new note let's make the title say hello", context: context()),
            .typeText(app: "Notes", text: "hello")
        )
    }

    func testGluedReactionIsDroppedOnlyFromOpens() throws {
        let xcom = try XCTUnwrap(URL(string: "https://x.com"))
        XCTAssertEqual(NativeClauseRouter.action(for: "Now can you open up x.com Nice", context: context(currentApp: nil)), .openURL(url: xcom, browser: nil))
        XCTAssertEqual(CommandLeadIn.stripTrailingReactions("open up x.com Nice, nice."), "open up x.com")
        XCTAssertEqual(CommandLeadIn.stripTrailingReactions("open Notes"), "open Notes")
        XCTAssertEqual(NativeClauseRouter.action(for: "type that looks nice", context: context()), .typeText(app: "Notes", text: "that looks nice"), "Typed text keeps every word.")
    }

    func testCleanupNeverInventsAnAction() {
        for clause in ["umce right there", "click Save", "summarize the page", "nice nice"] {
            XCTAssertNil(NativeClauseRouter.action(for: clause, context: context()), clause)
        }
    }
}
