import XCTest
@testable import Superkeet

final class RoutedIntentTests: XCTestCase {
    private let installed = ["Notes", "Calculator", "TextEdit", "Mail", "Safari", "Google Chrome"]

    private func context(currentApp: String? = "TextEdit") -> NativeClauseContext {
        NativeClauseContext(
            currentApp: currentApp,
            resolveApp: { [installed] name in
                let wanted = AppResolver.normalizedName(name)
                return installed.first { AppResolver.normalizedName($0) == wanted }
                    .map { URL(fileURLWithPath: "/Applications/\($0).app") }
            },
            isRunning: { _ in true }
        )
    }

    private func resolve(_ kind: RoutedIntent.Kind, _ argument: String? = nil, clause: String,
                         currentApp: String? = "TextEdit") -> RoutedIntentResolution {
        RoutedIntentResolver.resolve(RoutedIntent(kind: kind, argument: argument), clause: clause, context: context(currentApp: currentApp))
    }

    func testAnAppTheSpeakerMeantButDidNotNameOpensWhenItIsInstalled() {
        XCTAssertEqual(resolve(.openApp, "calculator", clause: "I need the calculator."), .action(.openApp(name: "Calculator")))
        XCTAssertEqual(resolve(.openApp, "Mail", clause: "Let me check my email real quick"), .action(.openApp(name: "Mail")),
                       "Opening an installed app runs without asking, so its name need not be spoken.")
        XCTAssertEqual(resolve(.openApp, "Figma", clause: "open up Figma"), .unresolved, "Not installed.")
        XCTAssertEqual(resolve(.openApp, nil, clause: "open it"), .unresolved)
    }

    func testTypedTextMustBeWordsTheSpeakerSaid() {
        XCTAssertEqual(resolve(.typeText, "quarterly review", clause: "The heading should be Quarterly Review."),
                       .action(.typeText(app: "TextEdit", text: "Quarterly Review")),
                       "The speaker's own spelling is typed, not the model's.")
        XCTAssertEqual(resolve(.typeText, "New Document", clause: "Start a fresh document."), .unresolved,
                       "The on-device model offered to type this; nobody said it.")
        XCTAssertEqual(resolve(.typeText, "review quarterly", clause: "The heading should be quarterly review."), .unresolved,
                       "The words must be in the order they were spoken.")
        XCTAssertEqual(resolve(.typeText, "hello", clause: "type hello", currentApp: nil), .unresolved, "Nowhere to type.")
    }

    func testTheWordsThatAskForTypingAreNeverTyped() {
        XCTAssertEqual(resolve(.typeText, "put in dear team comma running ten minutes late",
                               clause: "put in dear team comma running ten minutes late"), .unresolved,
                       "The on-device model returned the whole sentence as the text.")
        XCTAssertEqual(resolve(.typeText, "the heading should be", clause: "Okay, the heading should be quarterly review"), .unresolved,
                       "Lead-ins do not hide where the request starts.")
        XCTAssertEqual(resolve(.typeText, "dear team", clause: "put in dear team"), .action(.typeText(app: "TextEdit", text: "dear team")))
    }

    func testSpokenWordsIgnoreCasePunctuationAndSpacingButKeepTheSpeakersSpelling() {
        XCTAssertEqual(RoutedIntentResolver.spokenWords("dear team, running ten minutes late",
                                                        in: "Put in Dear team, running ten minutes late."),
                       "Dear team, running ten minutes late")
        XCTAssertEqual(RoutedIntentResolver.spokenWords("don't panic", in: "write don’t panic"), "don’t panic")
        XCTAssertEqual(RoutedIntentResolver.spokenWords("x.com", in: "Now can you open up x.com?"), "x.com")
        XCTAssertNil(RoutedIntentResolver.spokenWords("review", in: "preview the document"), "Whole words only.")
        XCTAssertNil(RoutedIntentResolver.spokenWords("  ", in: "anything"))
        XCTAssertNil(RoutedIntentResolver.spokenWords("one two three", in: "one two"))
    }

    func testASearchAndASiteUseTheSpeakersWords() throws {
        let search = try XCTUnwrap(NativeOpenAction.webSearchURL(for: "a good ramen recipe"))
        XCTAssertEqual(resolve(.webSearch, "a good ramen recipe", clause: "find me a good ramen recipe"),
                       .action(.openURL(url: search, browser: nil)))
        XCTAssertEqual(resolve(.webSearch, "best ramen in Tokyo", clause: "find me a good ramen recipe"), .unresolved)

        let lucky = try XCTUnwrap(NativeOpenAction.luckySearchURL(for: "Hacker News"))
        XCTAssertEqual(resolve(.openWebsite, "hacker news", clause: "Get me to Hacker News."), .action(.openURL(url: lucky, browser: nil)))
        XCTAssertEqual(resolve(.openWebsite, "https://news.ycombinator.com", clause: "Get me to Hacker News."), .unresolved,
                       "An address the speaker did not say is the model's guess.")
        XCTAssertEqual(resolve(.openWebsite, "github dot com", clause: "head over to github dot com"),
                       .action(.openURL(url: try XCTUnwrap(URL(string: "https://github.com")), browser: nil)))
    }

    func testAWholeSentenceIsNeverTheSearchOrTheSite() {
        XCTAssertEqual(resolve(.webSearch, "Summarize this page", clause: "Summarize this page."), .unresolved)
        XCTAssertEqual(resolve(.webSearch, "What time is it in Tokyo", clause: "What time is it in Tokyo?"), .unresolved)
        XCTAssertEqual(resolve(.openWebsite, "play my workout playlist", clause: "Play my workout playlist."), .unresolved)
    }

    func testAPageOpensInTheBrowserTheCommandIsAlreadyIn() throws {
        let url = try XCTUnwrap(NativeOpenAction.webSearchURL(for: "cats"))
        XCTAssertEqual(resolve(.webSearch, "cats", clause: "look for cats", currentApp: "Safari"),
                       .action(.openURL(url: url, browser: "Safari")))
    }

    func testShortcutsGoToTheCurrentApp() throws {
        let expected: [(RoutedIntent.Kind, [String])] = [
            (.newItem, ["cmd", "n"]), (.newTab, ["cmd", "t"]), (.save, ["cmd", "s"]), (.close, ["cmd", "w"]),
            (.undo, ["cmd", "z"]), (.redo, ["cmd", "shift", "z"]), (.selectAll, ["cmd", "a"]), (.quit, ["cmd", "q"])
        ]
        for (kind, keys) in expected {
            let shortcut = try XCTUnwrap(KeyboardShortcut(keys: keys))
            XCTAssertEqual(resolve(kind, clause: "whatever was said"), .action(.pressShortcut(app: "TextEdit", shortcut: shortcut)), "\(kind)")
            XCTAssertEqual(resolve(kind, clause: "whatever was said", currentApp: nil), .unresolved, "\(kind) with no app")
        }
    }

    func testOnlyANewItemOrTabRunsWithoutAskingLikeTheNativeRecipes() throws {
        for kind in RoutedIntent.Kind.allCases {
            guard case .action(let action) = resolve(kind, "hello", clause: "type hello"), case .pressShortcut = action else { continue }
            XCTAssertEqual(action.isApprovalExempt, [.newItem, .newTab].contains(kind), "\(kind)")
        }
    }

    func testARequestForNothingIsDroppedAndAnythingElseGoesToThePlanner() {
        XCTAssertEqual(resolve(.nothing, clause: "hmm let me think"), .nothing)
        XCTAssertEqual(resolve(.other, "the send button", clause: "click the send button"), .unresolved)
    }

    func testEveryKindHasAMeaningAndOnlyFourTakeAnArgument() {
        XCTAssertEqual(Set(RoutedIntent.Kind.allCases.map(\.rawValue)).count, RoutedIntent.Kind.allCases.count)
        XCTAssertTrue(RoutedIntent.Kind.allCases.allSatisfy { !$0.meaning.isEmpty })
        XCTAssertEqual(RoutedIntent.Kind.allCases.filter { $0.argumentMeaning != nil }, [.openApp, .openWebsite, .webSearch, .typeText])
        XCTAssertNil(RoutedIntent(kind: .typeText, argument: "  ").argument)
    }
}
