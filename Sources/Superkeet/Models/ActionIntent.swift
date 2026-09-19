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
}

protocol ActionIntentExtracting: Sendable {
    func extract(_ text: String) async throws -> ActionIntent
}

struct HeuristicIntentExtractor: ActionIntentExtracting {
    func extract(_ text: String) async throws -> ActionIntent {
        Self.intent(for: text)
    }

    static func intent(for text: String) -> ActionIntent {
        let goal = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let activeTab = ActiveTabIntent.extract(goal) { return activeTab }
        let words = goal.lowercased().split { !$0.isLetter }.map(String.init)
        // Prefer a named non-Chrome browser, preserving the existing filter's behavior.
        let browser = words.first { ActionIntentPolicy.browsers.contains($0) && $0 != "chrome" }
            ?? words.first { $0 == "chrome" }
        var intent = ActionIntent(goal: goal, action: .other, browser: browser)
        let lower = goal.lowercased()
        let verbs: [(String, ActionIntent.Action)] = [
            ("switch to ", .switchApp), ("open ", .openApp), ("launch ", .openApp),
            ("click ", .click), ("type ", .typeText), ("press ", .pressKey),
            ("scroll ", .scroll), ("search for ", .webSearch)
        ]
        if let (prefix, action) = verbs.first(where: { lower.hasPrefix($0.0) }) {
            let value = String(goal.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            intent = ActionIntent(goal: goal, action: action, browser: browser)
            switch action {
            case .openApp, .switchApp: intent.app = browser ?? value
            case .click: intent.target = value
            case .typeText: intent.text = value
            case .webSearch: intent.query = value
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
}
