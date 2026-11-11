import XCTest
@testable import Superkeet

/// Scores an intent router on phrasings the native routes were not written for. These run a real
/// model, so they are skipped unless asked for:
/// `SUPERKEET_FM_LIVE_TESTS=1 swift test --filter IntentRouterLiveTests` and read the `ROUTER` lines.
@MainActor
final class IntentRouterLiveTests: XCTestCase {
    struct Case {
        let clause: String
        let kinds: Set<RoutedIntent.Kind>
        let argument: String?

        init(_ clause: String, _ kinds: RoutedIntent.Kind..., argument: String? = nil) {
            self.clause = clause
            self.kinds = Set(kinds)
            self.argument = argument
        }
    }

    static let cases: [Case] = [
        Case("can you open up the notes app for me", .openApp, argument: "Notes"),
        Case("umce right there can you create a new note", .newItem),
        Case("inside this new node, let's make the title say hello", .typeText, argument: "hello"),
        Case("can you open up the Arc browser", .openApp, argument: "Arc"),
        Case("once you're there, can you Google search Norbert Wiener", .webSearch, argument: "Norbert Wiener"),
        Case("Now can you open up x.com Nice", .openWebsite, argument: "x.com"),
        Case("Great, great. Okay let's move on", .nothing),
        Case("Cool, awesome. Thank you.", .nothing),
        Case("I need my calendar", .openApp, argument: "Calendar"),
        Case("get me to Slack", .openApp, argument: "Slack"),
        Case("bring Spotify to the front", .openApp, argument: "Spotify"),
        Case("jump over to the terminal", .openApp, argument: "Terminal"),
        Case("take me to the New York Times", .openWebsite, argument: "the New York Times"),
        Case("head over to github dot com slash anthropics", .openWebsite, argument: "github dot com slash anthropics"),
        Case("what's the weather in Lisbon this weekend", .other, .webSearch),
        Case("find me a good ramen recipe", .webSearch, argument: "a good ramen recipe"),
        Case("see what the internet says about the M5 MacBook", .webSearch, argument: "the M5 MacBook"),
        Case("jot down buy oat milk", .typeText, argument: "buy oat milk"),
        Case("put in dear team comma running ten minutes late", .typeText, argument: "dear team comma running ten minutes late"),
        Case("the heading should be quarterly review", .typeText, argument: "quarterly review"),
        Case("start a fresh note", .newItem),
        Case("give me a blank document", .newItem),
        Case("I want another tab", .newTab),
        Case("get rid of this window", .close),
        Case("scratch that last thing", .undo),
        Case("hit save", .save),
        Case("click the send button", .other),
        Case("reply to the latest email from Dana saying I'll be there", .other),
        Case("turn the volume down a bit", .other),
        Case("move this window to the left half of the screen", .other),
        Case("hmm let me think", .nothing),
        Case("hold on, someone's at the door", .nothing),
        Case("no that's not right", .nothing, .undo),
        Case("how many tabs do I have open", .other),
        Case("summarize this page", .other),
        Case("I need the calculator.", .openApp, argument: "Calculator"),
        Case("Jump back over to TextEdit.", .openApp, argument: "TextEdit"),
        Case("Start a fresh document.", .newItem),
        Case("The heading should be quarterly review.", .typeText, argument: "quarterly review"),
        Case("Get me to Hacker News.", .openWebsite, argument: "Hacker News"),
        Case("What time is it in Tokyo?", .other, .webSearch),
        Case("select everything", .selectAll),
        Case("put that back", .redo, .undo)
    ]

    private static let installed = ["Notes", "Arc", "Calendar", "Slack", "Spotify", "Terminal", "Calculator", "TextEdit",
                                    "Safari", "Mail", "Messages", "Music", "Finder", "Photo Booth"]

    private func context() -> NativeClauseContext {
        let apps = Self.installed.map { URL(fileURLWithPath: "/fixture/\($0).app") }
        let resolver = AppResolver(directories: [URL(fileURLWithPath: "/fixture")], applicationsInDirectory: { _ in apps })
        return NativeClauseContext(currentApp: "TextEdit", resolveApp: { resolver.resolve($0) }, isRunning: { _ in true })
    }

    func score(_ router: any IntentRouting, name: String) async -> (kind: Int, resolved: Int, harmful: Int) {
        let clock = ContinuousClock()
        var kindRight = 0, resolvedRight = 0, harmful = 0
        var times: [Duration] = []
        router.prewarm()
        try? await Task.sleep(for: .seconds(2))
        for item in Self.cases {
            let started = clock.now
            let intent = await router.route(item.clause, currentApp: "TextEdit")
            let elapsed = clock.now - started
            times.append(elapsed)
            let resolution = intent.map { RoutedIntentResolver.resolve($0, clause: item.clause, context: context()) } ?? .unresolved
            let kindOK = intent.map { item.kinds.contains($0.kind) } ?? false
            if kindOK { kindRight += 1 }
            // What the user would get: the right action, or a safe hand-off for "other" and "nothing".
            let wantsAction = !item.kinds.isDisjoint(with: Set(RoutedIntent.Kind.allCases).subtracting([.other, .nothing]))
            let outcome: String
            switch resolution {
            case .action(let action):
                let right = kindOK && Self.argumentMatches(action, item.argument)
                if right { resolvedRight += 1 } else { harmful += 1 }
                outcome = right ? "right action" : "WRONG ACTION"
                _ = action
            case .nothing:
                if item.kinds.contains(.nothing) { resolvedRight += 1; outcome = "dropped, as it should" } else { harmful += 1; outcome = "WRONGLY DROPPED" }
            case .unresolved:
                if !wantsAction || item.kinds.contains(.other) { resolvedRight += 1; outcome = "to planner, as it should" } else { outcome = "to planner (missed)" }
            }
            print("ROUTER \(name) \(elapsed) \(kindOK ? "ok " : "XX ") \(intent?.kind.rawValue ?? "nil") “\(intent?.argument ?? "")” => \(outcome) | \(item.clause)")
        }
        let sorted = times.sorted()
        print("ROUTER \(name) SUMMARY kind \(kindRight)/\(Self.cases.count), outcome right \(resolvedRight)/\(Self.cases.count), harmful \(harmful); "
              + "median \(sorted[sorted.count / 2]), slowest \(sorted[sorted.count - 1])")
        return (kindRight, resolvedRight, harmful)
    }

    private static func argumentMatches(_ action: NativeOpenAction, _ expected: String?) -> Bool {
        guard let expected else { return true }
        let wanted = expected.lowercased()
        switch action {
        case .openApp(let name): return name.lowercased() == wanted
        case .typeText(_, let text): return text.lowercased() == wanted
        case .openURL(let url, _):
            if let query = NativeOpenAction.webSearchQuery(from: url.absoluteString) {
                let said = query.lowercased()
                return said.contains(wanted) || wanted.contains(said)
            }
            return wanted.contains(url.host?.lowercased().replacingOccurrences(of: "www.", with: "") ?? "\u{0}")
                || url.absoluteString.lowercased().contains(wanted.replacingOccurrences(of: " dot ", with: ".").replacingOccurrences(of: " slash ", with: "/"))
        case .pressShortcut: return true
        }
    }

    /// The held-out set: today's routing first, then the router on what it leaves to the planner,
    /// exactly as `AgentSessionController` asks it. Writes `.build/paraphrase-coverage/report-<name>.md`.
    func scoreOnParaphrases(_ router: any IntentRouting, name: String) async throws -> (passed: Int, wrong: Int) {
        let fixture = try ParaphraseCoverageTests.loadFixture()
        let regex = RegexParaphraseRouter(installedApps: fixture.installedApps)
        let clock = ContinuousClock()
        var results: [(command: ParaphraseFixture.Command, route: ScoredRoute, passed: Bool)] = []
        var times: [Duration] = []
        var wrong = 0, asked = 0
        router.prewarm()
        try? await Task.sleep(for: .seconds(2))
        for command in fixture.commands {
            var route = regex.route(command.text, currentApp: command.currentApp)
            var fromRouter = false
            if route.tool == .planner {
                asked += 1
                let started = clock.now
                let intent = await router.route(command.text, currentApp: command.currentApp)
                times.append(clock.now - started)
                let context = NativeClauseContext(currentApp: command.currentApp, resolveApp: regex.resolve, isRunning: { _ in true })
                switch intent.map({ RoutedIntentResolver.resolve($0, clause: command.text, context: context) }) ?? .unresolved {
                case .action(let action):
                    route = regex.scored(action, note: "router read \(intent?.kind.rawValue ?? "?")")
                    fromRouter = true
                case .nothing:
                    route = ScoredRoute(tool: .none, note: "router read nothing")
                    fromRouter = true
                case .unresolved:
                    route.note = intent.map { "router read \($0.kind.rawValue) “\($0.argument ?? "")”, unresolved" } ?? "router could not tell"
                }
            }
            let passed = ParaphraseScorer.passes(route, command.expect)
            if fromRouter, !passed { wrong += 1 }
            results.append((command, route, passed))
        }
        let sorted = times.sorted()
        let timing = sorted.isEmpty ? "" : "Router asked \(asked) times: median \(sorted[sorted.count / 2]), slowest \(sorted[sorted.count - 1]). "
        let report = ParaphraseCoverageTests.report(router: "regex, then \(name)", results: results)
            + "\n\(timing)Wrong actions or wrongly dropped by the router: \(wrong).\n"
        let url = ParaphraseCoverageTests.root.appendingPathComponent(".build/paraphrase-coverage/report-\(name).md")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try report.write(to: url, atomically: true, encoding: .utf8)
        print("PARAPHRASE \(name): \(results.filter(\.passed).count)/\(results.count) pass, \(wrong) wrong from the router. \(timing)")
        return (results.filter(\.passed).count, wrong)
    }

    func testOnDeviceRouterOnParaphrases() async throws {
        guard ProcessInfo.processInfo.environment["SUPERKEET_FM_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set SUPERKEET_FM_LIVE_TESTS=1 to exercise the on-device model.")
        }
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), AppleIntelligenceAvailability.current.isAvailable else {
            throw XCTSkip("Apple Intelligence is not available on this machine.")
        }
        _ = try await scoreOnParaphrases(FoundationModelIntentRouter(), name: "on-device")
        #else
        throw XCTSkip("FoundationModels is not available in this SDK.")
        #endif
    }

    func testDecisionModelRouterOnParaphrases() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SUPERKEET_OLLAMA_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set SUPERKEET_OLLAMA_LIVE_TESTS=1 to exercise a local decision model.")
        }
        var configuration = OllamaDecisionIntentRouter.Configuration()
        configuration.model = environment["SUPERKEET_OLLAMA_MODEL"] ?? configuration.model
        configuration.timeout = 60
        let router = OllamaDecisionIntentRouter(configuration: configuration)
        guard await router.route("okay", currentApp: nil) != nil else {
            throw XCTSkip("Ollama is not serving \(configuration.model) on this machine.")
        }
        _ = try await scoreOnParaphrases(router, name: configuration.model)
    }

    func testOnDeviceRouter() async throws {
        guard ProcessInfo.processInfo.environment["SUPERKEET_FM_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set SUPERKEET_FM_LIVE_TESTS=1 to exercise the on-device model.")
        }
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), AppleIntelligenceAvailability.current.isAvailable else {
            throw XCTSkip("Apple Intelligence is not available on this machine.")
        }
        let result = await score(FoundationModelIntentRouter(), name: "on-device")
        // Measured on macOS 27.2: 36 of 43 kinds, 3 wrong actions (two on clauses the native
        // routes take first). More than that is a regression in the prompt or the guards.
        XCTAssertLessThanOrEqual(result.harmful, 3, "The on-device router did more wrong things than it used to.")
        XCTAssertGreaterThanOrEqual(result.kind, 34)
        #else
        throw XCTSkip("FoundationModels is not available in this SDK.")
        #endif
    }

    /// `SUPERKEET_OLLAMA_LIVE_TESTS=1 swift test --filter IntentRouterLiveTests/testDecisionModelRouter`
    /// needs Ollama running with the model in `SUPERKEET_OLLAMA_MODEL` (default clef-flash).
    func testDecisionModelRouter() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SUPERKEET_OLLAMA_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set SUPERKEET_OLLAMA_LIVE_TESTS=1 to exercise a local decision model.")
        }
        var configuration = OllamaDecisionIntentRouter.Configuration()
        configuration.model = environment["SUPERKEET_OLLAMA_MODEL"] ?? configuration.model
        configuration.timeout = 60
        let router = OllamaDecisionIntentRouter(configuration: configuration)
        guard await router.route("okay", currentApp: nil) != nil else {
            throw XCTSkip("Ollama is not serving \(configuration.model) on this machine.")
        }
        let result = await score(router, name: configuration.model)
        XCTAssertEqual(result.harmful, 0, "A router may miss; it must not do the wrong thing.")
    }
}
