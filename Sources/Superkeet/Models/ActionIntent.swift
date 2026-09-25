import Foundation

struct ActionIntent: Codable, Equatable, Sendable {
    enum Action: String, Codable, CaseIterable, Sendable {
        case openApp = "open_app"
        case openURL = "open_url"
        case webSearch = "web_search"
        case navigate, find
        case switchApp = "switch_app"
        case click
        case typeText = "type_text"
        case pressKey = "press_key"
        case scroll
        case readScreen = "read_screen"
        case other
    }

    enum Scope: String, Codable, Sendable {
        case activeTab = "active_tab"
    }

    let goal: String
    let action: Action
    var app: String?
    var browser: String?
    var url: String?
    var query: String?
    var target: String?
    var text: String?
    var scope: Scope?

    var routingTerms: Set<String> {
        Set(goal.lowercased().split { !$0.isLetter && !$0.isNumber }
            .filter { $0.count >= 3 }.map(String.init))
    }
}

enum ActionIntentPolicy {
    static let browsers: Set<String> = [
        "chrome", "safari", "helium", "firefox", "edge", "brave", "arc",
        "opera", "vivaldi", "chromium", "dia", "orion", "floorp", "zen"
    ]

    static func excludesChromeAutomation(_ intent: ActionIntent) -> Bool {
        guard let browser = intent.browser?.lowercased() else { return false }
        return browser != "chrome" && browsers.contains(browser)
    }

    static func targetsActiveChromeTab(_ intent: ActionIntent) -> Bool {
        guard intent.scope == .activeTab else { return false }
        return intent.browser == nil || ["chrome", "google chrome"].contains(intent.browser?.lowercased() ?? "")
    }

    /// Whether an app name refers to a web browser ("Google Chrome", "Helium browser", "Safari").
    static func isBrowserName(_ appName: String) -> Bool {
        let normalized = AppResolver.normalizedName(appName)
        return browsers.contains(normalized)
            || ["google chrome", "microsoft edge"].contains(normalized)
            || normalized.split(separator: " ").contains { browsers.contains(String($0)) }
    }
}

enum HeuristicIntentExtractor {
    /// Verb prefixes and the action each one implies; longer phrases first so "open up" wins over "open".
    static let verbs: [(prefix: String, action: ActionIntent.Action)] = [
        ("switch over to ", .switchApp), ("switch to ", .switchApp), ("activate ", .switchApp), ("bring up ", .switchApp),
        // "go search …" is how people say it, and how the recogniser often hears "Google search".
        ("go search for ", .webSearch), ("go search ", .webSearch),
        ("go to ", .switchApp),
        ("open up ", .openApp), ("open ", .openApp), ("launch ", .openApp), ("pull up ", .openApp), ("fire up ", .openApp),
        ("start ", .openApp), ("show me ", .openApp),
        ("click ", .click), ("type ", .typeText), ("press ", .pressKey), ("scroll ", .scroll),
        ("do a google search for ", .webSearch), ("do a web search for ", .webSearch), ("do a search for ", .webSearch),
        ("run a search for ", .webSearch), ("perform a search for ", .webSearch),
        ("google search for ", .webSearch), ("google search ", .webSearch), ("search google for ", .webSearch),
        ("search on google for ", .webSearch), ("search the web for ", .webSearch), ("web search for ", .webSearch),
        ("web search ", .webSearch), ("search up ", .webSearch), ("search for ", .webSearch), ("search ", .webSearch),
        ("google ", .webSearch), ("look up ", .webSearch), ("lookup ", .webSearch)
    ]

    private static let trailingBrowser = try? NSRegularExpression(
        pattern: #"\s+(?:in|on|using|with|via|inside)\s+(?:the\s+)?([^,;]+?)\s*\z"#, options: .caseInsensitive
    )

    static func intent(for text: String) -> ActionIntent {
        let original = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let activeTab = ActiveTabIntent.extract(original) { return activeTab }
        let goal = SpokenURL.normalize(CommandLeadIn.strip(original))
        let words = goal.lowercased().split { !$0.isLetter }.map(String.init)
        let browser = words.first { ActionIntentPolicy.browsers.contains($0) && $0 != "chrome" }
            ?? words.first { $0 == "chrome" }
        var intent = ActionIntent(goal: goal, action: .other, browser: browser)
        let lower = goal.lowercased()
        if let (prefix, action) = verbs.first(where: { lower.hasPrefix($0.prefix) }) {
            let value = String(goal.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            intent = ActionIntent(goal: goal, action: action, browser: browser)
            switch action {
            case .openApp, .switchApp: intent.app = browser ?? CommandLeadIn.stripTrailing(value)
            case .click: intent.target = value
            case .typeText: intent.text = value
            case .webSearch: intent.query = searchQuery(from: CommandLeadIn.stripTrailing(value))
            default: break
            }
        } else if lower == "read screen" || lower == "read the screen" {
            intent = ActionIntent(goal: goal, action: .readScreen, browser: browser)
        }
        let tokens = goal.split(whereSeparator: \.isWhitespace).map { NativeOpenAction.spokenURLToken(String($0)) }
        if let url = tokens.first(where: { token in
            token.hasPrefix("https://") || token.hasPrefix("http://")
                || ActionArgumentNormalizer.normalizedURL(token) != nil
        }), lower.hasPrefix("open ") || lower.hasPrefix("go to ") || lower.contains(" and go to ") {
            intent = ActionIntent(
                goal: goal, action: .openURL, app: browser, browser: browser,
                url: ActionArgumentNormalizer.normalizedURL(url) ?? url
            )
        }
        return intent
    }

    private static let leadingSearchWord = try? NSRegularExpression(
        pattern: #"\A(?:(?:google\s+)?search|for|up|on\s+google\s+for)\b[.,;:!?]*\s+"#, options: .caseInsensitive
    )

    /// Drops a trailing "in Chrome" / "using Safari" from a search query. Other trailing phrases
    /// ("restaurants in Paris") are part of the query and stay.
    static func searchQuery(from value: String) -> String {
        var query = value.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;:!?")))
        // "Google search. Simon Cowell": the recogniser's punctuation after the verb is not the query.
        for _ in 0..<2 {
            guard let leadingSearchWord,
                  let match = leadingSearchWord.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)),
                  let range = Range(match.range, in: query) else { break }
            query = String(query[range.upperBound...])
        }
        if let trailingBrowser,
           let match = trailingBrowser.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)),
           let nameRange = Range(match.range(at: 1), in: query),
           ActionIntentPolicy.isBrowserName(String(query[nameRange])),
           let wholeRange = Range(match.range, in: query) {
            query = String(query[..<wholeRange.lowerBound])
        }
        query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // "search for" with nothing after it: the verb matched but there is no query.
        return ["for", "the web for", "the web"].contains(query.lowercased()) ? "" : query
    }
}
