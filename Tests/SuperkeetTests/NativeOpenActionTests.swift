import XCTest
@testable import Superkeet

final class NativeOpenActionTests: XCTestCase {
    private func fast(_ text: String) -> NativeOpenAction? {
        NativeOpenAction.fastPath(for: HeuristicIntentExtractor.intent(for: text))
    }

    func testSimpleAppCommands() {
        XCTAssertEqual(fast("open discord"), .openApp(name: "discord"))
        XCTAssertEqual(fast("Open Helium browser."), .openApp(name: "Helium browser."))
        XCTAssertEqual(fast("Launch Calculator"), .openApp(name: "Calculator"))
        XCTAssertEqual(fast("Open Helium preferences"), .openApp(name: "Helium preferences"),
                       "Resolution should fail on the full name rather than silently opening just Helium.")
    }

    func testExplicitTabScopeCannotUseNativeOpenEvenWithOpenURLAction() throws {
        let intent = ActionIntent(goal: "open youtube.com", action: .openURL, url: "https://youtube.com", scope: .activeTab)
        XCTAssertNil(NativeOpenAction.fastPath(for: intent))
    }

    func testCombinedOpenAndNavigateIsOneNativeURLOpen() throws {
        let url = try XCTUnwrap(URL(string: "https://youtube.com"))
        XCTAssertEqual(fast("open Helium and go to youtube.com"), .openURL(url: url, browser: "Helium"))
        XCTAssertEqual(fast("Open Google Chrome browser and go to youtube.com."), .openURL(url: url, browser: "Google Chrome browser"))
        XCTAssertEqual(fast("Open My Browser and go to youtube.com"), .openURL(url: url, browser: "My Browser"))
    }

    func testURLUsesOnlyExplicitlyNamedBrowser() throws {
        let url = try XCTUnwrap(URL(string: "https://youtube.com"))
        XCTAssertEqual(fast("open youtube.com."), .openURL(url: url, browser: nil))
        XCTAssertEqual(fast("Go to youtube.com in Helium"), .openURL(url: url, browser: "Helium"))
        let browserWordInHost = try XCTUnwrap(URL(string: "https://helium.com"))
        XCTAssertEqual(fast("open https://helium.com"), .openURL(url: browserWordInHost, browser: nil))
        let sequenceWordInURL = try XCTUnwrap(URL(string: "https://example.com/and?next=then"))
        XCTAssertEqual(fast("open https://example.com/and?next=then"), .openURL(url: sequenceWordInURL, browser: nil))
    }

    func testCompoundRequestsCannotDropLaterSteps() {
        for text in [
            "open Helium and search for cats", "open Discord then click Friends", "open Discord; quit Notes",
            "open Helium and go to youtube.com and search for cats", "open youtube.com then close the tab",
            "open youtube.com in Helium and clear history", "open Helium and go to youtube.com; quit Discord",
            "open Helium. Go to youtube.com", "Search for cats", "Click Save in Notes"
        ] {
            XCTAssertNil(fast(text), text)
        }
    }

    func testNativeArgumentsRoundTripWithoutShellSyntax() throws {
        let action = NativeOpenAction.openApp(name: "An App; $(whoami)")
        XCTAssertEqual(try NativeOpenAction.decode(toolName: action.toolName, argumentsJSON: action.argumentsJSON()), action)
        let openURL = try NativeOpenAction.decode(toolName: "open_url", argumentsJSON: #"{"url":"youtube.com","browser":"Helium"}"#)
        XCTAssertEqual(openURL, .openURL(url: try XCTUnwrap(URL(string: "https://youtube.com")), browser: "Helium"))
        XCTAssertEqual(try NativeOpenAction.decode(toolName: openURL.toolName, argumentsJSON: openURL.argumentsJSON()), openURL)
        XCTAssertEqual(try NativeOpenAction.decode(toolName: "open_url", argumentsJSON: #"{"url":"https://example.com","browser":null}"#),
                       .openURL(url: try XCTUnwrap(URL(string: "https://example.com")), browser: nil))
    }

    func testMalformedArgumentsAreRejected() {
        for (tool, json) in [
            ("open_app", #"{"name":""}"#), ("open_app", #"{"name":1}"#), ("open_app", #"{"command_line":"open -a Helium"}"#),
            ("open_url", #"{"url":"file:///tmp/example"}"#), ("open_url", #"{"url":"https://"}"#),
            ("open_url", #"{"url":"youtube.com and quit"}"#), ("open_url", #"{"url":"youtube.com","browser":false}"#),
            ("open_url", #"{"url":"https://example.com","argv":[]}"#), ("run_process", "{}"),
            ("press_shortcut", #"{"app":"Notes"}"#), ("press_shortcut", #"{"app":"Notes","keys":[]}"#),
            ("press_shortcut", #"{"app":"Notes","keys":["n"]}"#), ("press_shortcut", #"{"app":"Notes","keys":["cmd","power"]}"#),
            ("press_shortcut", #"{"app":"","keys":["cmd","n"]}"#), ("press_shortcut", #"{"app":"Notes","keys":"cmd+n"}"#),
            ("press_shortcut", #"{"app":"Notes","keys":["cmd","n"],"pid":1}"#),
            ("press_shortcut", #"{"app":"Notes","keys":["cmd","shift","option","ctrl","fn","n"]}"#)
        ] {
            XCTAssertThrowsError(try NativeOpenAction.decode(toolName: tool, argumentsJSON: json), json)
        }
    }

    func testShortcutArgumentsRoundTrip() throws {
        let chord = try XCTUnwrap(KeyboardShortcut(keys: ["cmd", "shift", "z"]))
        let action = NativeOpenAction.pressShortcut(app: "Notes", shortcut: chord)
        XCTAssertEqual(action.toolName, "press_shortcut")
        XCTAssertEqual(action.spec, NativeOpenAction.tools[2])
        let json = try action.argumentsJSON()
        XCTAssertEqual(json, #"{"app":"Notes","keys":["shift","cmd","z"]}"#)
        XCTAssertEqual(try NativeOpenAction.decode(toolName: "press_shortcut", argumentsJSON: json), action)
        XCTAssertEqual(try NativeOpenAction.decode(toolName: "press_shortcut", argumentsJSON: #"{"app":"Notes","keys":["Command","N"]}"#),
                       .pressShortcut(app: "Notes", shortcut: try XCTUnwrap(KeyboardShortcut(keys: ["cmd", "n"]))))
    }

    func testSchemasAreCompactDescribedAndMutating() throws {
        for spec in NativeOpenAction.tools {
            XCTAssertEqual(spec.serverName, "superkeet")
            XCTAssertEqual(spec.risk, .mutating)
            XCTAssertLessThan(spec.inputSchemaJSON.count, 500)
            let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(spec.inputSchemaJSON.utf8)) as? [String: Any])
            let properties = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
            XCTAssertTrue(properties.values.allSatisfy { ($0["description"] as? String)?.isEmpty == false })
        }
        XCTAssertEqual(NativeOpenAction.prependingTools(to: NativeOpenAction.tools), NativeOpenAction.tools)
    }
}
