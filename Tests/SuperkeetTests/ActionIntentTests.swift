import XCTest
@testable import Superkeet

final class ActionIntentTests: XCTestCase {
    func testNamedBrowserAndURL() {
        let intent = HeuristicIntentExtractor.intent(for: "Open Helium and go to youtube.com")
        XCTAssertEqual(intent.action, .openURL)
        XCTAssertEqual(intent.browser, "helium")
        XCTAssertEqual(intent.url, "https://youtube.com")
        XCTAssertTrue(ActionIntentPolicy.excludesChromeAutomation(intent))
    }

    func testLiteralSlotsPreserveCaseAndText() {
        XCTAssertEqual(HeuristicIntentExtractor.intent(for: "Open Calculator").app, "Calculator")
        XCTAssertEqual(HeuristicIntentExtractor.intent(for: "Switch to Notes").action, .switchApp)
        XCTAssertEqual(HeuristicIntentExtractor.intent(for: "Click Save As").target, "Save As")
        XCTAssertEqual(HeuristicIntentExtractor.intent(for: "Type Hello, world!").text, "Hello, world!")
        XCTAssertEqual(HeuristicIntentExtractor.intent(for: "Search for red pandas").query, "red pandas")
    }

    func testLeadInsAndExtraVerbsAreRecognised() {
        XCTAssertEqual(HeuristicIntentExtractor.intent(for: "Lets open Chrome and search for Morgan Freeman").action, .openApp)
        XCTAssertEqual(HeuristicIntentExtractor.intent(for: "please open Chrome").app, "chrome")
        XCTAssertEqual(HeuristicIntentExtractor.intent(for: "I want to pull up Notes").action, .openApp)
        XCTAssertEqual(HeuristicIntentExtractor.intent(for: "I want to pull up Notes").app, "Notes")
        XCTAssertEqual(HeuristicIntentExtractor.intent(for: "fire up Calculator").action, .openApp)
        XCTAssertEqual(HeuristicIntentExtractor.intent(for: "show me the weather").app, "the weather")
        XCTAssertEqual(HeuristicIntentExtractor.intent(for: "bring up Discord").action, .switchApp)
        XCTAssertEqual(HeuristicIntentExtractor.intent(for: "go to Notes").action, .switchApp)
        XCTAssertEqual(HeuristicIntentExtractor.intent(for: "Lets open youtube.com").action, .openURL)
    }

    func testWebSearchQueryDropsOnlyATrailingBrowser() {
        let chrome = HeuristicIntentExtractor.intent(for: "search for Morgan Freeman in Chrome")
        XCTAssertEqual(chrome.action, .webSearch)
        XCTAssertEqual(chrome.query, "Morgan Freeman")
        XCTAssertEqual(chrome.browser, "chrome")
        XCTAssertEqual(HeuristicIntentExtractor.intent(for: "google Morgan Freeman").query, "Morgan Freeman")
        XCTAssertEqual(HeuristicIntentExtractor.intent(for: "look up the capital of Peru").query, "the capital of Peru")
        XCTAssertEqual(HeuristicIntentExtractor.intent(for: "search the web for cats").query, "cats")
        XCTAssertEqual(HeuristicIntentExtractor.intent(for: "search cats.").query, "cats")
        XCTAssertEqual(HeuristicIntentExtractor.intent(for: "search for restaurants in Paris").query, "restaurants in Paris")
        XCTAssertEqual(HeuristicIntentExtractor.intent(for: "search for Morgan Freeman using the Safari browser").query, "Morgan Freeman")
        XCTAssertEqual(HeuristicIntentExtractor.intent(for: "search for Morgan Freeman using the Safari browser").browser, "safari")
    }

    func testUnsupportedIntentsAndBrowserWordBoundaries() {
        XCTAssertEqual(HeuristicIntentExtractor.intent(for: "Please organize my files").action, .other)
        XCTAssertNil(HeuristicIntentExtractor.intent(for: "Open archive").browser)
        XCTAssertFalse(ActionIntentPolicy.excludesChromeAutomation(HeuristicIntentExtractor.intent(for: "Open Chrome")))
        XCTAssertEqual(HeuristicIntentExtractor.intent(for: "Type youtube.com").action, .typeText)
    }

    func testActiveTabNavigationTakesPrecedenceOverNativeOpen() {
        for command in [
            "In the current tab, go to youtube.com", "Open youtube.com in the active Chrome tab",
            "Navigate the current tab to youtube.com", "Use the current Google Chrome tab to open youtube.com",
            "In Chrome’s active tab, please visit youtube.com", "Go to youtube.com in the current tab of Chrome"
        ] {
            let intent = HeuristicIntentExtractor.intent(for: command)
            XCTAssertEqual(intent.action, .navigate, command)
            XCTAssertEqual(intent.scope, .activeTab, command)
            XCTAssertEqual(intent.browser, "chrome", command)
            XCTAssertEqual(intent.url, "https://youtube.com", command)
            XCTAssertNil(NativeOpenAction.fastPath(for: intent), command)
        }
    }

    func testActiveTabFindPreservesQueryAndDoesNotInferBrowserFromContent() {
        let intent = HeuristicIntentExtractor.intent(for: "In the current Chrome tab, find Safari DNS instructions for catacolabs.com")
        XCTAssertEqual(intent.action, .find)
        XCTAssertEqual(intent.scope, .activeTab)
        XCTAssertEqual(intent.browser, "chrome")
        XCTAssertEqual(intent.query, "Safari DNS instructions for catacolabs.com")
        XCTAssertNil(intent.url)
    }

    func testCloudflareZoneIsNotMisreadAsDestinationWebsite() {
        let intent = HeuristicIntentExtractor.intent(for: "In the active tab, open Cloudflare DNS for catacolabs.com")
        XCTAssertEqual(intent.action, .navigate)
        XCTAssertEqual(intent.scope, .activeTab)
        XCTAssertNil(intent.url)
        XCTAssertTrue(intent.routingTerms.isSuperset(of: ["cloudflare", "dns"]))
    }

    func testExplicitNonChromeTabQualifierIsPreserved() {
        for (command, browser) in [
            ("In the current Safari tab, find DNS", "safari"),
            ("In Firefox's active tab, go to example.com", "firefox"),
            ("Find DNS in the active tab of Helium", "helium")
        ] {
            let intent = HeuristicIntentExtractor.intent(for: command)
            XCTAssertEqual(intent.scope, .activeTab)
            XCTAssertEqual(intent.browser, browser)
            XCTAssertFalse(ActionIntentPolicy.targetsActiveChromeTab(intent))
        }
    }

    func testTabWordsInQuotedPayloadOrLongerWordsDoNotChangeScope() {
        for command in [
            #"Type "in the active tab" into Message in Notes"#,
            "Type ‘in the current tab’ into Message in Notes", #"Click "Current tab" in Notes"#,
            "Read the current table", "Find inactive tabs", "Open Chrome and go to youtube.com"
        ] {
            XCTAssertNil(HeuristicIntentExtractor.intent(for: command).scope, command)
        }
    }

    func testLegacyIntentDecodesAndActiveTabScopeRoundTrips() throws {
        let legacy = try JSONDecoder().decode(ActionIntent.self, from: Data(#"{"goal":"Open Notes","action":"open_app","app":"Notes"}"#.utf8))
        XCTAssertNil(legacy.scope)
        let scoped = HeuristicIntentExtractor.intent(for: "Find DNS records in the active tab")
        XCTAssertEqual(try JSONDecoder().decode(ActionIntent.self, from: JSONEncoder().encode(scoped)), scoped)
    }
}
