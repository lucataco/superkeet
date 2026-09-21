import XCTest
@testable import Superkeet

final class SpokenURLTests: XCTestCase {
    func testJoinsSpokenDotsAndSlashes() {
        XCTAssertEqual(SpokenURL.normalize("open X dot com"), "open X.com")
        XCTAssertEqual(SpokenURL.normalize("go to www dot youtube dot com slash trending"), "go to www.youtube.com/trending")
        XCTAssertEqual(SpokenURL.normalize("open Notes"), "open Notes")
        XCTAssertEqual(SpokenURL.normalize("polka dot dress"), "polka dot dress", "Only real top-level domains join.")
    }

    func testSpokenDomainsBecomeNativeOpens() throws {
        let intent = HeuristicIntentExtractor.intent(for: "open X dot com.")
        XCTAssertEqual(intent.action, .openURL)
        XCTAssertEqual(intent.url, "https://X.com")
        XCTAssertEqual(NativeOpenAction.fastPath(for: intent), .openURL(url: try XCTUnwrap(URL(string: "https://X.com")), browser: nil))
        XCTAssertEqual(HeuristicIntentExtractor.intent(for: "open X dot com in Helium").browser, "helium")
        XCTAssertTrue(CommandClauses.startsClause("x dot com"), "A spoken address starts a step like a written one.")
    }
}

final class ClauseSplitFollowupTests: XCTestCase {
    func testSentenceEndFollowedByAConnectorSplitsAndTheConnectorIsDropped() {
        XCTAssertEqual(CommandClauses.split("open the Chrome browser. And"), ["open the Chrome browser"])
        let intent = HeuristicIntentExtractor.intent(for: "open the Chrome browser. And")
        XCTAssertEqual(intent.action, .openApp)
        XCTAssertEqual(intent.browser, "chrome")
        XCTAssertEqual(HeuristicIntentExtractor.intent(for: "open the Notes app. And").app, "the Notes app")
        XCTAssertEqual(
            NativeOpenAction.fastPath(for: HeuristicIntentExtractor.intent(for: "open the Chrome browser. And")),
            .openApp(name: "the Chrome browser")
        )
    }

    func testDoASearchForIsASearchClause() {
        XCTAssertEqual(
            CommandClauses.split("open the Chrome browser and let's do a search for Morgan Freeman."),
            ["open the Chrome browser", "let's do a search for Morgan Freeman"]
        )
        let search = HeuristicIntentExtractor.intent(for: "let's do a search for Morgan Freeman.")
        XCTAssertEqual(search.action, .webSearch)
        XCTAssertEqual(search.query, "Morgan Freeman")
        XCTAssertNil(
            NativeOpenAction.fastPath(for: HeuristicIntentExtractor.intent(for: "open the Chrome browser and let's do a search for Morgan Freeman.")),
            "A compound command never becomes one app name."
        )
    }

    func testPunctuationAfterTheSearchVerbStaysOutOfTheQuery() {
        XCTAssertEqual(HeuristicIntentExtractor.intent(for: "Google search. Simon Cowell").query, "Simon Cowell")
        XCTAssertEqual(HeuristicIntentExtractor.intent(for: "search for, cats").query, "cats")
        XCTAssertEqual(HeuristicIntentExtractor.intent(for: "search for Morgan Freeman").query, "Morgan Freeman")
    }

    func testLongPhrasesAreNeverAppNames() {
        XCTAssertFalse(NativeOpenAction.isPlausibleAppName("the Chrome browser and let's do a search for Morgan Freeman"))
        XCTAssertTrue(NativeOpenAction.isPlausibleAppName("the Notes app"))
        XCTAssertTrue(NativeOpenAction.isPlausibleAppName("Visual Studio Code"))
        XCTAssertNil(NativeOpenAction.fastPath(for: HeuristicIntentExtractor.intent(for: "open the thing I was looking at yesterday before lunch")))
    }
}

final class AppResolverFuzzyTests: XCTestCase {
    private let system = URL(fileURLWithPath: "/fixture/Applications")
    private var apps: [URL] { ["Google Chrome", "Notes", "Helium", "Photo Booth", "Discord"].map { system.appendingPathComponent("\($0).app") } }
    private var resolver: AppResolver {
        let apps = self.apps
        return AppResolver(directories: [system], applicationsInDirectory: { _ in apps })
    }

    func testMisheardNamesResolveToTheAppThatSoundsTheSameWhenAsked() {
        XCTAssertEqual(resolver.resolve("the crown", fuzzy: true)?.lastPathComponent, "Google Chrome.app")
        XCTAssertEqual(resolver.resolve("nodes", fuzzy: true)?.lastPathComponent, "Notes.app")
        XCTAssertNil(resolver.resolve("the crown"), "Exact by default: nothing launched mid-sentence rides on a guess.")
        XCTAssertNil(resolver.resolve("nodes"))
    }

    func testPartialAndUnrelatedNamesStayUnresolvedEvenFuzzily() {
        XCTAssertNil(resolver.resolve("Heli", fuzzy: true), "A prefix is not a sound-alike.")
        XCTAssertNil(resolver.resolve("Missing", fuzzy: true))
        XCTAssertNil(resolver.resolve("in the tab", fuzzy: true))
        XCTAssertNil(resolver.resolve("cat", fuzzy: true))
    }

    func testAliasesCoverEverydayNames() {
        XCTAssertEqual(resolver.resolve("the camera")?.lastPathComponent, "Photo Booth.app")
        var identifiers: [String] = []
        _ = resolver.resolve("email") { identifiers.append($0); return nil }
        XCTAssertEqual(identifiers, ["com.apple.mail"])
    }

    func testSoundexAndEditDistance() {
        XCTAssertEqual(AppResolver.soundex("crown"), "C650")
        XCTAssertEqual(AppResolver.soundex("chrome"), "C650")
        XCTAssertEqual(AppResolver.soundex("helium"), "H450")
        XCTAssertEqual(AppResolver.soundex("heli"), "H400")
        XCTAssertEqual(AppResolver.soundex(""), "")
        XCTAssertEqual(AppResolver.editDistance("crown", "chrome"), 3)
        XCTAssertEqual(AppResolver.editDistance("notes", "nodes"), 1)
        XCTAssertEqual(AppResolver.editDistance("", "abc"), 3)
    }
}

final class HousekeepingToolFilterTests: XCTestCase {
    func testHousekeepingToolsNeverReachThePlanner() {
        let server = UUID()
        let tools = ["click", "check_permissions", "get_cursor_position", "kill_app", "list_windows", "start_recording", "zoom"].map { name in
            ActionToolSpec(descriptor: MCPToolDescriptor(serverID: server, serverName: "cua-driver", name: name, title: nil,
                                                         description: "", risk: .mutating, inputSchemaJSON: "{}"))
        }
        XCTAssertEqual(ActionToolFilter.filtering(tools, task: "click Save").map(\.toolName), ["click", "list_windows"])
    }
}

final class ObservationSessionTests: XCTestCase {
    private func object(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    func testEverySessionAwareToolGetsTheCommandLabel() throws {
        var binding = ObservationBinding()
        binding.sessionLabel = "sk-test"
        let schema = #"{"type":"object","properties":{"session":{"type":"string"},"url":{"type":"string"}}}"#
        let browser = try object(binding.completing(argumentsJSON: #"{"url":"https://x.com"}"#, schemaJSON: schema, currentPID: nil, toolName: "browser_navigate"))
        XCTAssertEqual(browser["session"] as? String, "sk-test")
        let other = try object(binding.completing(argumentsJSON: #"{"url":"https://x.com","session":"made-up"}"#, schemaJSON: schema, currentPID: nil, toolName: "click"))
        XCTAssertEqual(other["session"] as? String, "sk-test")
        binding.absorb(resultJSON: #"{"session":"srv-1","elements":[]}"#, toolName: "get_window_state")
        let issued = try object(binding.completing(argumentsJSON: #"{"url":"https://x.com"}"#, schemaJSON: schema, currentPID: nil, toolName: "click"))
        XCTAssertEqual(issued["session"] as? String, "sk-test", "The command label remains stable across observations.")
        XCTAssertTrue(ObservationBinding.newSessionLabel().hasPrefix("sk-"))
        XCTAssertEqual(ObservationBinding.newSessionLabel().count, 11)
    }

    func testMissingWindowIsReportedForThePidThatNeedsOne() {
        let schema = #"{"type":"object","properties":{"pid":{"type":"integer"},"window_id":{"type":"integer"}},"required":["pid","window_id"]}"#
        let binding = ObservationBinding()
        XCTAssertEqual(binding.missingWindowPID(argumentsJSON: #"{"pid":91}"#, schemaJSON: schema), 91)
        XCTAssertEqual(binding.missingWindowPID(argumentsJSON: #"{"pid":91,"window_id":7}"#, schemaJSON: schema), 91)
        XCTAssertNil(binding.missingWindowPID(argumentsJSON: "{}", schemaJSON: schema), "No pid, nothing to list.")
        XCTAssertNil(binding.missingWindowPID(argumentsJSON: #"{"pid":91}"#, schemaJSON: #"{"type":"object","properties":{"pid":{"type":"integer"}}}"#))
    }
}

@MainActor
final class NativeExecutorResolutionTests: XCTestCase {
    func testWholeSentencesFailFastWithoutScanning() async throws {
        let scans = OSAllocatedUnfairLockBox(0)
        let apps = [URL(fileURLWithPath: "/fixture/Applications/Notes.app")]
        let resolver = AppResolver(directories: [URL(fileURLWithPath: "/fixture/Applications")], applicationsInDirectory: { _ in
            scans.mutate { $0 += 1 }
            return apps
        })
        let executor = NativeActionExecutor(
            resolver: resolver, workspace: NativeActionExecutorTests.Workspace(),
            shortcuts: NativeActionExecutorTests.Shortcuts(), typer: NativeTypeTextTests.Typer()
        )
        let sentence = "the Chrome browser and let's do a search for Morgan Freeman"
        do {
            _ = try await executor.execute(.openApp(name: sentence))
            XCTFail("Expected a fast miss")
        } catch { XCTAssertEqual(error as? NativeOpenActionError, .appNotFound(sentence)) }
        XCTAssertEqual(scans.value, 0, "A sentence is refused before the disk is touched.")
        _ = try await executor.execute(.openApp(name: "Notes"))
        XCTAssertGreaterThan(scans.value, 0)
    }
}

@MainActor
final class ObservationCompletionTests: XCTestCase {
    private let notes = URL(fileURLWithPath: "/fixture/Applications/Notes.app")
    private let cua = UUID()

    private func spec(_ name: String, schema: String) -> ActionToolSpec {
        var spec = ActionToolSpec(descriptor: MCPToolDescriptor(
            serverID: cua, serverName: "cua-driver", name: name, title: nil, description: "", risk: .readOnly, inputSchemaJSON: schema
        ))
        spec.compactObservation = true
        spec.requiresFreshObservation = true
        return spec
    }

    private func object(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func waitUntilFinished(_ controller: AgentSessionController) async {
        let deadline = Date().addingTimeInterval(5)
        while controller.phase.isActive && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    func testWindowListIsFetchedBeforeACallThatNeedsAWindowID() async throws {
        let windows = spec("list_windows", schema: #"{"type":"object","properties":{"pid":{"type":"integer"},"session":{"type":"string"},"on_screen_only":{"type":"boolean"}}}"#)
        let state = spec("get_window_state", schema: #"""
        {"type":"object","properties":{"pid":{"type":"integer"},"window_id":{"type":"integer"},"session":{"type":"string"},"include_screenshot":{"type":"boolean"}},"required":["pid","window_id"]}
        """#)
        let router = AgentSessionControllerTests.FakeRouter(specs: [windows, state])
        router.outputs["open_app"] = NativeLaunchedApp(name: "Notes", bundleIdentifier: "com.apple.Notes", processIdentifier: 91, windowReady: true).summary
        router.outputs["list_windows"] = #"{"windows":[{"pid":91,"window_id":7,"z_index":3,"is_on_screen":true,"app_name":"Notes"}]}"#
        router.outputs["get_window_state"] = #"{"pid":91,"window_id":7,"snapshot_id":"s0000abcd","app_name":"Notes","elements":[]}"#
        let planner = AgentSessionControllerTests.SequencePlanner([(tool: "get_window_state", arguments: #"{"window_id":1,"include_screenshot":false}"#)])
        let controller = AgentSessionController(
            settings: .shared, router: router, plannerFactory: { planner },
            resolveApp: { [notes] in AppResolver.normalizedName($0).contains("notes") ? notes : nil }, isAppRunning: { _ in true },
            frontmostApp: { nil }
        )
        controller.handleCommand("open Notes and read the screen")
        await waitUntilFinished(controller)

        XCTAssertEqual(router.executed, ["open_app", "list_windows", "get_window_state"])
        XCTAssertEqual(try object(router.arguments[1])["pid"] as? Int, 91)
        let stateArguments = try object(router.arguments[2])
        XCTAssertEqual(stateArguments["pid"] as? Int, 91)
        XCTAssertEqual(stateArguments["window_id"] as? Int, 7, "The window came from Superkeet's own list_windows, not the model.")
        XCTAssertEqual(stateArguments["include_screenshot"] as? Bool, false)
        let label = try XCTUnwrap(stateArguments["session"] as? String)
        XCTAssertTrue(label.hasPrefix("sk-"))
        XCTAssertEqual(try object(router.arguments[1])["session"] as? String, label)
        if case .finished = controller.phase {} else { XCTFail("Expected success, got \(controller.phase)") }
    }

    func testTheAppOfThePreviousUtteranceCarriesThroughASession() async throws {
        let router = AgentSessionControllerTests.FakeRouter(specs: [])
        router.preparationFailure = ActionExecutionError.noMCPServersEnabled
        router.outputs["open_app"] = NativeLaunchedApp(name: "Notes", bundleIdentifier: "com.apple.Notes", processIdentifier: 91, windowReady: true).summary
        router.outputs["type_text"] = "Typed “hello” in Notes (pid 91)."
        let controller = AgentSessionController(
            settings: .shared, router: router, plannerFactory: { nil },
            resolveApp: { [notes] in AppResolver.normalizedName($0).contains("notes") ? notes : nil }, isAppRunning: { [notes] in $0 == notes },
            frontmostApp: { nil },
            isListeningSessionActive: { true }
        )
        controller.handleCommand("open Notes")
        await waitUntilFinished(controller)
        XCTAssertEqual(controller.carriedApp?.name, "Notes")

        controller.handleCommand("type hello")
        await waitUntilFinished(controller)
        XCTAssertEqual(router.executed, ["open_app", "type_text"], "The next utterance already knows it is in Notes.")
        XCTAssertEqual(try NativeOpenAction.decode(toolName: "type_text", argumentsJSON: XCTUnwrap(router.arguments.last)),
                       .typeText(app: "Notes", text: "hello"))

        controller.forgetCarriedContext()
        XCTAssertNil(controller.carriedApp)
        controller.handleCommand("type hello")
        await waitUntilFinished(controller)
        XCTAssertEqual(router.executed.count, 2, "With no carried app and nothing in front, typing has no native target.")
    }
}
