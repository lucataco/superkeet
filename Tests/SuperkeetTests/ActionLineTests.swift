import XCTest
@testable import Superkeet

final class ActionLineTests: XCTestCase {
    private func shortcut(_ keys: String...) throws -> KeyboardShortcut {
        try XCTUnwrap(KeyboardShortcut(keys: keys))
    }

    func testClauseTitlesDropLeadInsAndReadAsASentence() {
        XCTAssertEqual(ActionLineText.clause("Can you open up Text Edit for me?"), "Open up Text Edit")
        XCTAssertEqual(ActionLineText.clause("And once you're there, can you create a new document?"), "Create a new document")
        XCTAssertEqual(ActionLineText.clause("let's make the title say hello."), "Make the title say hello")
        XCTAssertEqual(ActionLineText.clause("summarize the page"), "Summarize the page")
        XCTAssertEqual(ActionLineText.clause("please"), "Please", "A clause that is only a lead-in keeps its words rather than becoming blank.")
    }

    func testOpeningAnAppReadsAsACommandThenInThePastTenseWithTheRealName() {
        let action = NativeOpenAction.openApp(name: "text edit")
        XCTAssertEqual(action.lineTitle(), "Open text edit")
        let launched = NativeLaunchedApp(name: "TextEdit", bundleIdentifier: "com.apple.TextEdit", processIdentifier: 4039, windowReady: false)
        XCTAssertEqual(action.lineDoneTitle(output: launched.summary), "Opened TextEdit")
        XCTAssertEqual(action.lineDoneTitle(), "Opened text edit", "Without output, the spoken name stands.")
    }

    func testShortcutsReadAsTheThingTheUserAskedFor() throws {
        let newDocument = NativeOpenAction.pressShortcut(app: "TextEdit", shortcut: try shortcut("cmd", "n"))
        XCTAssertEqual(newDocument.lineDoneTitle(clause: "can you create a new document"), "New document")
        XCTAssertEqual(newDocument.lineTitle(clause: "And once you're there, can you create a new document?"), "New document")
        XCTAssertEqual(newDocument.lineDoneTitle(), "Pressed ⌘N in TextEdit", "With no clause to read, the key press is named.")

        let save = NativeOpenAction.pressShortcut(app: "Notes", shortcut: try shortcut("cmd", "s"))
        XCTAssertEqual(save.lineDoneTitle(clause: "save it"), "Save in Notes")
        let quit = NativeOpenAction.pressShortcut(app: "Notes", shortcut: try shortcut("cmd", "q"))
        XCTAssertEqual(quit.lineDoneTitle(clause: "quit"), "Quit Notes")
        XCTAssertEqual(save.lineDoneTitle(clause: "create a new note"), "Pressed ⌘S in Notes", "A recipe for a different chord does not rename it.")
    }

    func testTypingAndWebStepsNameTheWordsOrThePlace() throws {
        XCTAssertEqual(NativeOpenAction.typeText(app: "TextEdit", text: "hello").lineDoneTitle(), "Typed “hello”")
        XCTAssertEqual(NativeOpenAction.typeText(app: "TextEdit", text: "hello").lineTitle(), "Type “hello”")
        let search = NativeOpenAction.openURL(url: try XCTUnwrap(URL(string: "https://www.google.com/search?q=cats")), browser: "Safari")
        XCTAssertEqual(search.lineDoneTitle(), "Searched for “cats” in Safari")
        XCTAssertEqual(search.lineTitle(), "Search for “cats” in Safari")
        let site = NativeOpenAction.openURL(url: try XCTUnwrap(URL(string: "https://www.youtube.com")), browser: nil)
        XCTAssertEqual(site.lineDoneTitle(), "Opened youtube.com")
    }

    func testReasonsAreOneSentenceWithoutCodesOrIdentifiers() {
        XCTAssertEqual(ActionLineText.reason(from: "Couldn't read the page. No browser tools are enabled."), "Couldn't read the page.")
        XCTAssertEqual(ActionLineText.reason(from: "Could not reach youtube.com right now. Try again."), "Could not reach youtube.com right now.",
                       "A dot inside an address does not end the sentence.")
        XCTAssertEqual(ActionLineText.reason(from: "The tool get_browser_state returned an error: no CDP endpoint."),
                       "The tool returned an error: no CDP endpoint.")
        XCTAssertEqual(ActionLineText.reason(from: "Launch refused (NSPOSIXErrorDomain error 3)."), "Launch refused.")
        XCTAssertEqual(ActionLineText.reason(from: "Opened Notes (pid 12, com.apple.Notes) but it quit."), "Opened Notes but it quit.")
        XCTAssertNil(ActionLineText.reason(from: "browser_requires_setup"))
        XCTAssertEqual(ActionLineText.reason(from: String(repeating: "word ", count: 60))?.count, ActionLineText.maximumReasonLength + 1)
    }

    func testPlainOutputDropsProcessAndWindowBookkeeping() {
        XCTAssertEqual(ActionLineText.plain("Opened TextEdit (pid 4039, com.apple.TextEdit). No window has appeared yet. Typed “hello” in TextEdit (pid 4039)."),
                       "Opened TextEdit. Typed “hello” in TextEdit.")
    }

    func testEarlyActivityBecomesTheSameLinesAsTheRun() throws {
        let app = NativeLaunchedApp(name: "TextEdit", bundleIdentifier: "com.apple.TextEdit", processIdentifier: 4039, windowReady: false)
        let newDocument = SpeculativeStep(index: 1, clause: "can you create a new document",
                                          action: .pressShortcut(app: "TextEdit", shortcut: try shortcut("cmd", "n")), sequence: 4)
        let typed = SpeculativeStep(index: 2, clause: "make the title say hello",
                                    action: .typeText(app: "TextEdit", text: "hello"), sequence: 6)
        let lines = ActionLine.early(
            activity: .launched(app),
            steps: [
                .done(SpeculativeStepResult(step: newDocument, output: "Pressed ⌘N in TextEdit (pid 4039).", failure: nil)),
                .running(typed)
            ]
        )
        XCTAssertEqual(lines, [
            ActionLine(status: .done, title: "Opened TextEdit"),
            ActionLine(status: .done, title: "New document"),
            ActionLine(status: .running, title: "Type “hello”")
        ])

        let failed = ActionLine.early(
            activity: .failed("Helium", "Launch refused. Try again."),
            steps: [.failed(SpeculativeStepResult(step: typed, output: nil, failure: "TextEdit is not running."))]
        )
        XCTAssertEqual(failed, [
            ActionLine(status: .failed(reason: "Launch refused."), title: "Open Helium"),
            ActionLine(status: .failed(reason: "TextEdit is not running."), title: "Type “hello”")
        ])
        XCTAssertEqual(ActionLine.early(activity: .launching("Notes"), steps: []), [ActionLine(status: .running, title: "Open Notes")])
        XCTAssertTrue(ActionLine.early(activity: nil, steps: []).isEmpty)
    }
}
