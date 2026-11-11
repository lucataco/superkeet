import XCTest
@testable import Superkeet

/// What a router decided for one spoken command, reduced to the parts the paraphrase fixture
/// scores: the tool, its key argument, and the app it acts in.
struct ScoredRoute: Equatable {
    enum Tool: String {
        case openApp = "open_app"
        case openURL = "open_url"
        case pressShortcut = "press_shortcut"
        case typeText = "type_text"
        case none
        case planner
    }

    var tool: Tool
    /// open_app: resolved app name. open_url: the full URL. press_shortcut: chord such as
    /// "cmd+n". type_text: the exact text.
    var argument: String?
    var app: String?
    /// Free-form note for the report, such as how the command was split.
    var note: String?

    var summary: String {
        var parts = [tool.rawValue]
        if let argument { parts.append(argument) }
        if let app { parts.append("in \(app)") }
        if let note { parts.append("(\(note))") }
        return parts.joined(separator: " ")
    }
}

/// Anything that can be scored against `Tests/Fixtures/paraphrases/commands.json`: today's regex
/// routing, or a future semantic router. `installedApps` is the fixture's inventory.
protocol ParaphraseRouter {
    var name: String { get }
    func route(_ text: String, currentApp: String?) -> ScoredRoute
}

/// Today's routing, in the order `AgentSessionController.run` applies it to a whole command:
/// dropped filler, the whole-command native open, then the clause router and the typing
/// fallback. Every fixture app is installed and running, and `currentApp` is the app carried
/// from an earlier step, which is also frontmost.
struct RegexParaphraseRouter: ParaphraseRouter {
    let name = "regex (NativeClauseRouter)"
    let resolver: AppResolver

    init(installedApps: [String]) {
        let directory = URL(fileURLWithPath: "/fixture/Applications", isDirectory: true)
        let urls = installedApps.map { directory.appendingPathComponent("\($0).app") }
        resolver = AppResolver(directories: [directory], applicationsInDirectory: { _ in urls })
    }

    func resolve(_ name: String) -> URL? {
        guard NativeOpenAction.isPlausibleAppName(name) else { return nil }
        return resolver.resolve(name, fuzzy: true)
    }

    func route(_ text: String, currentApp: String?) -> ScoredRoute {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let clauses = CommandClauses.split(trimmed)
        if clauses.isEmpty { return ScoredRoute(tool: .none) }
        let context = NativeClauseContext(currentApp: currentApp, resolveApp: resolve, isRunning: { _ in true })

        let intent = HeuristicIntentExtractor.intent(for: trimmed)
        if let action = wholeCommandOpen(intent, context: context) {
            return scored(action, note: "whole-command open")
        }
        let note = clauses.count > 1 ? "split into \(clauses.count): \(clauses.joined(separator: " | "))" : nil
        for clause in clauses {
            if let action = NativeClauseRouter.action(for: clause, context: context) {
                return scored(action, note: note)
            }
            if clauses.count > 1, let action = wholeCommandOpen(HeuristicIntentExtractor.intent(for: clause), context: context) {
                return scored(action, note: note)
            }
            if let recipe = NativeTypeRecipe.recipe(for: clause), let target = NativeClauseRouter.typeTarget(recipe, context: context) {
                return scored(.typeText(app: target.app, text: target.text), note: note)
            }
        }
        return ScoredRoute(tool: .planner, note: note)
    }

    /// Mirrors `AgentSessionController.nativeOpen(for:context:)`.
    private func wholeCommandOpen(_ intent: ActionIntent, context: NativeClauseContext) -> NativeOpenAction? {
        guard let action = NativeOpenAction.fastPath(for: intent) else { return nil }
        if case .openApp(let name) = action, resolve(name) == nil, NativeAppRecipe.recipe(for: intent.goal) != nil { return nil }
        return NativeClauseRouter.resolvingOpen(action, context: context)
    }

    func scored(_ action: NativeOpenAction, note: String?) -> ScoredRoute {
        switch action {
        case .openApp(let name):
            let resolved = resolve(name)?.deletingPathExtension().lastPathComponent
            return ScoredRoute(tool: .openApp, argument: resolved ?? "unresolved “\(name)”", note: note)
        case .openURL(let url, let browser):
            return ScoredRoute(tool: .openURL, argument: url.absoluteString, app: browser, note: note)
        case .pressShortcut(let app, let shortcut):
            return ScoredRoute(tool: .pressShortcut, argument: shortcut.keys.joined(separator: "+"), app: app, note: note)
        case .typeText(let app, let text):
            return ScoredRoute(tool: .typeText, argument: text, app: app, note: note)
        }
    }
}

struct ParaphraseFixture: Decodable {
    struct Expectation: Decodable {
        let tool: String
        let arg: String?
        let app: String?
        let search: Bool?
        let lucky: String?
    }

    struct Command: Decodable {
        let text: String
        let category: String
        let source: String
        let currentApp: String?
        let expect: Expectation

        enum CodingKeys: String, CodingKey {
            case text, category, source, expect
            case currentApp = "current_app"
        }
    }

    let installedApps: [String]
    let commands: [Command]

    enum CodingKeys: String, CodingKey {
        case commands
        case installedApps = "installed_apps"
    }
}

enum ParaphraseScorer {
    static func passes(_ route: ScoredRoute, _ expected: ParaphraseFixture.Expectation) -> Bool {
        guard route.tool.rawValue == expected.tool else { return false }
        if let app = expected.app, !same(route.app, app) { return false }
        switch route.tool {
        case .none, .planner:
            return true
        case .openApp:
            return same(route.argument, expected.arg)
        case .typeText:
            return same(route.argument, expected.arg)
        case .pressShortcut:
            return chord(route.argument) == chord(expected.arg)
        case .openURL:
            guard let argument = route.argument, let components = URLComponents(string: argument) else { return false }
            let isLucky = components.queryItems?.contains { $0.name == "btnI" } ?? false
            if expected.search == true {
                guard !isLucky, let query = NativeOpenAction.webSearchQuery(from: argument) else { return false }
                return normalizedQuery(query) == normalizedQuery(expected.arg ?? "")
            }
            if isLucky {
                let query = components.queryItems?.first { $0.name == "q" }?.value ?? ""
                return expected.lucky.map { normalizedQuery($0) == normalizedQuery(query) } ?? false
            }
            return host(components.host) == host(expected.arg)
        }
    }

    private static func same(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return lhs == rhs }
        return lhs.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(rhs.trimmingCharacters(in: .whitespaces)) == .orderedSame
    }

    private static func chord(_ text: String?) -> [String] {
        let order = ["ctrl", "control", "option", "shift", "cmd"]
        let parts = (text ?? "").lowercased().split(separator: "+").map(String.init)
        let modifiers = parts.filter(order.contains).sorted { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) }
        return modifiers + parts.filter { !order.contains($0) }
    }

    private static func host(_ text: String?) -> String {
        let lowered = (text ?? "").lowercased()
        return lowered.hasPrefix("www.") ? String(lowered.dropFirst(4)) : lowered
    }

    private static func normalizedQuery(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
    }
}

/// Scores today's router against the paraphrase fixture and writes
/// `.build/paraphrase-coverage/report.md`. Individual misses never fail the test; a category
/// whose pass count falls below `Tests/Fixtures/paraphrases/baseline.json` does.
///
/// To update the baseline after a routing improvement, run
/// `PARAPHRASE_UPDATE_BASELINE=1 swift test --filter ParaphraseCoverageTests`, check the
/// report, and commit the rewritten baseline.json. Never lower a count by hand to make a
/// regression pass.
final class ParaphraseCoverageTests: XCTestCase {
    private struct Baseline: Codable {
        var router: String
        var total: Int
        var passed: Int
        var categories: [String: Int]
    }

    static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private var root: URL { Self.root }

    private var fixtures: URL { root.appendingPathComponent("Tests/Fixtures/paraphrases") }

    static func loadFixture() throws -> ParaphraseFixture {
        let data = try Data(contentsOf: root.appendingPathComponent("Tests/Fixtures/paraphrases/commands.json"))
        return try JSONDecoder().decode(ParaphraseFixture.self, from: data)
    }

    private func loadFixture() throws -> ParaphraseFixture { try Self.loadFixture() }

    func testFixtureIsWellFormed() throws {
        let fixture = try loadFixture()
        XCTAssertGreaterThanOrEqual(fixture.commands.count, 70)
        let tools = Set(["open_app", "open_url", "press_shortcut", "type_text", "none", "planner"])
        for command in fixture.commands {
            XCTAssertTrue(tools.contains(command.expect.tool), command.text)
            XCTAssertTrue(["docs", "natural"].contains(command.source), command.text)
            if !["none", "planner"].contains(command.expect.tool) { XCTAssertNotNil(command.expect.arg, command.text) }
            if let app = command.currentApp { XCTAssertTrue(fixture.installedApps.contains(app), command.text) }
        }
    }

    func testScorerComparesKeyArguments() throws {
        let search = ParaphraseFixture.Expectation(tool: "open_url", arg: "morgan freeman", app: nil, search: true, lucky: nil)
        let url = try XCTUnwrap(NativeOpenAction.webSearchURL(for: "Morgan Freeman"))
        XCTAssertTrue(ParaphraseScorer.passes(ScoredRoute(tool: .openURL, argument: url.absoluteString), search))
        let lucky = try XCTUnwrap(NativeOpenAction.luckySearchURL(for: "Morgan Freeman"))
        XCTAssertFalse(ParaphraseScorer.passes(ScoredRoute(tool: .openURL, argument: lucky.absoluteString), search))

        let site = ParaphraseFixture.Expectation(tool: "open_url", arg: "youtube.com", app: nil, search: nil, lucky: nil)
        XCTAssertTrue(ParaphraseScorer.passes(ScoredRoute(tool: .openURL, argument: "https://www.youtube.com/"), site))
        XCTAssertFalse(ParaphraseScorer.passes(ScoredRoute(tool: .openURL, argument: "https://youtu.be/"), site))

        let redo = ParaphraseFixture.Expectation(tool: "press_shortcut", arg: "cmd+shift+z", app: "TextEdit", search: nil, lucky: nil)
        XCTAssertTrue(ParaphraseScorer.passes(ScoredRoute(tool: .pressShortcut, argument: "shift+cmd+z", app: "textedit"), redo))
        XCTAssertFalse(ParaphraseScorer.passes(ScoredRoute(tool: .pressShortcut, argument: "shift+cmd+z", app: "Notes"), redo))

        let typed = ParaphraseFixture.Expectation(tool: "type_text", arg: "Hello", app: nil, search: nil, lucky: nil)
        XCTAssertTrue(ParaphraseScorer.passes(ScoredRoute(tool: .typeText, argument: "hello", app: "Notes"), typed))
        XCTAssertFalse(ParaphraseScorer.passes(ScoredRoute(tool: .typeText, argument: "hello.", app: "Notes"), typed))
        XCTAssertFalse(ParaphraseScorer.passes(ScoredRoute(tool: .planner), typed))
    }

    func testRegexRouterCoverageDoesNotRegress() throws {
        let fixture = try loadFixture()
        let router = RegexParaphraseRouter(installedApps: fixture.installedApps)
        let results = fixture.commands.map { command in
            (command, router.route(command.text, currentApp: command.currentApp))
        }.map { command, route in (command: command, route: route, passed: ParaphraseScorer.passes(route, command.expect)) }

        let report = Self.report(router: router.name, results: results)
        print(report)
        let reportURL = root.appendingPathComponent(".build/paraphrase-coverage/report.md")
        try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try report.write(to: reportURL, atomically: true, encoding: .utf8)

        var measured = Baseline(router: router.name, total: results.count, passed: results.filter(\.passed).count, categories: [:])
        for result in results {
            measured.categories[result.command.category, default: 0] += result.passed ? 1 : 0
        }

        let baselineURL = fixtures.appendingPathComponent("baseline.json")
        if ProcessInfo.processInfo.environment["PARAPHRASE_UPDATE_BASELINE"] == "1" {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try (encoder.encode(measured) + Data("\n".utf8)).write(to: baselineURL)
            return
        }
        let baseline = try JSONDecoder().decode(Baseline.self, from: Data(contentsOf: baselineURL))
        for (category, floor) in baseline.categories.sorted(by: { $0.key < $1.key }) {
            let passed = measured.categories[category] ?? 0
            XCTAssertGreaterThanOrEqual(passed, floor, "\(category) regressed: \(passed) passing, baseline \(floor). See \(reportURL.path)")
        }
    }

    static func report(
        router: String, results: [(command: ParaphraseFixture.Command, route: ScoredRoute, passed: Bool)]
    ) -> String {
        func rate(_ subset: [(command: ParaphraseFixture.Command, route: ScoredRoute, passed: Bool)]) -> String {
            let passed = subset.filter(\.passed).count
            let percent = subset.isEmpty ? 0 : Int((Double(passed) / Double(subset.count) * 100).rounded())
            return "\(passed)/\(subset.count) (\(percent)%)"
        }
        var lines = ["# Paraphrase coverage: \(router)", "", "Overall: \(rate(results))", ""]
        lines += ["| Category | Passed |", "|---|---|"]
        var categories: [String] = []
        for result in results where !categories.contains(result.command.category) { categories.append(result.command.category) }
        for category in categories {
            lines.append("| \(category) | \(rate(results.filter { $0.command.category == category })) |")
        }
        lines += ["", "| Source | Passed |", "|---|---|"]
        for source in ["docs", "natural"] {
            lines.append("| \(source) | \(rate(results.filter { $0.command.source == source })) |")
        }
        lines += ["", "## Misses", ""]
        for result in results where !result.passed {
            let expect = result.command.expect
            let expected = [expect.tool, expect.arg, expect.app.map { "in \($0)" }].compactMap { $0 }.joined(separator: " ")
            let context = result.command.currentApp.map { "current \($0)" } ?? "no current app"
            lines.append("- [\(result.command.category), \(result.command.source)] “\(result.command.text)” (\(context))")
            lines.append("  - expected: \(expected)")
            lines.append("  - routed: \(result.route.summary)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
