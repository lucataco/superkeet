import Foundation

enum NativeOpenActionError: LocalizedError, Equatable {
    case appNotFound(String)
    case appNotRunning(String)
    case accessibilityRequired
    case invalidArguments(String)
    case openFailed(String)

    var errorDescription: String? {
        switch self {
        case .appNotFound(let name): return "Could not find an installed app named '\(name)'."
        case .appNotRunning(let name): return "'\(name)' is not running, so no keyboard shortcut was sent."
        case .accessibilityRequired: return "Sending keyboard shortcuts needs Accessibility access for Superkeet."
        case .invalidArguments(let message): return message
        case .openFailed(let message): return "macOS could not complete the open request: \(message)"
        }
    }
}

enum NativeOpenAction: Equatable, Sendable {
    case openApp(name: String)
    case openURL(url: URL, browser: String?)
    case pressShortcut(app: String, shortcut: KeyboardShortcut)
    case typeText(app: String, text: String)

    static let maximumTypedCharacters = 4_000
    static let maximumAppNameWords = 6

    /// Six words is already generous for an app name; anything longer is the rest of the
    /// sentence, and resolving it would only waste a scan before the planner takes over.
    static func isPlausibleAppName(_ name: String) -> Bool {
        let words = AppResolver.normalizedName(name).split(whereSeparator: \.isWhitespace)
        return !words.isEmpty && words.count <= maximumAppNameWords
    }

    static let serverID = UUID(uuid: (0x53, 0x55, 0x50, 0x45, 0x52, 0x4b, 0x45, 0x45, 0x80, 0, 0, 0, 0, 0, 0, 1))
    static let tools = [
        tool(name: "open_app", title: "Open App", description: "Open an installed macOS app by name, such as Discord or Helium. No shell command is needed.", schema: #"""
        {"type":"object","properties":{"name":{"type":"string","description":"Installed app name, e.g. Discord or Helium."}},"required":["name"],"additionalProperties":false}
        """#),
        tool(name: "open_url", title: "Open URL", description: "Open a web URL in the named browser, or the default browser when browser is omitted.", schema: #"""
        {"type":"object","properties":{"url":{"type":"string","format":"uri","description":"Complete http:// or https:// URL."},"browser":{"type":"string","description":"Optional installed browser name, e.g. Helium or Google Chrome."}},"required":["url"],"additionalProperties":false}
        """#),
        tool(name: "press_shortcut", title: "Press Shortcut", description: "Press a keyboard shortcut in a running app, e.g. keys [\"cmd\",\"n\"] for New or [\"cmd\",\"s\"] for Save. The app is brought to the front first.", schema: #"""
        {"type":"object","properties":{"app":{"type":"string","description":"Running app name, e.g. Notes."},"keys":{"type":"array","items":{"type":"string"},"description":"Modifiers then one key, e.g. [\"cmd\",\"shift\",\"z\"]. Keys: letters, digits, return, tab, space, delete, escape, arrows."}},"required":["app","keys"],"additionalProperties":false}
        """#),
        tool(name: "type_text", title: "Type Text", description: "Type text into a running app at its current insertion point, exactly as given. The app is brought to the front first.", schema: #"""
        {"type":"object","properties":{"app":{"type":"string","description":"Running app name, e.g. Notes."},"text":{"type":"string","description":"The exact text to type. Use \n for a new line."}},"required":["app","text"],"additionalProperties":false}
        """#)
    ]

    /// The tool this action runs as. Approval exemption is decided per action: opening an app or
    /// URL never asks under the default policy, and neither do the harmless ⌘N / ⌘T shortcuts.
    var spec: ActionToolSpec {
        var spec: ActionToolSpec
        switch self {
        case .openApp: spec = Self.tools[0]
        case .openURL: spec = Self.tools[1]
        case .pressShortcut: spec = Self.tools[2]
        case .typeText: spec = Self.tools[3]
        }
        spec.approvalExempt = isApprovalExempt
        return spec
    }

    /// Shortcuts that only create something new and can always be undone by closing it.
    static let benignShortcuts: Set<KeyboardShortcut> = Set([["cmd", "n"], ["cmd", "t"], ["return"]].compactMap { KeyboardShortcut(keys: $0) })

    /// Typing the words the user just dictated into the app they named is what they asked for,
    /// so like opening an app it runs without a card under the default policy.
    var isApprovalExempt: Bool {
        switch self {
        case .openApp, .openURL, .typeText: return true
        case .pressShortcut(_, let shortcut): return Self.benignShortcuts.contains(shortcut)
        }
    }

    var toolName: String {
        switch self {
        case .openApp: return "open_app"
        case .openURL: return "open_url"
        case .pressShortcut: return "press_shortcut"
        case .typeText: return "type_text"
        }
    }

    func argumentsJSON() throws -> String {
        try validate()
        let arguments: [String: Any]
        switch self {
        case .openApp(let name): arguments = ["name": name]
        case .openURL(let url, let browser):
            arguments = ["url": url.absoluteString].merging(browser.map { ["browser": $0] } ?? [:]) { _, new in new }
        case .pressShortcut(let app, let shortcut):
            arguments = ["app": app, "keys": shortcut.keys]
        case .typeText(let app, let text):
            arguments = ["app": app, "text": text]
        }
        let data = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw NativeOpenActionError.invalidArguments("Could not encode the open request.")
        }
        return json
    }

    func validate() throws {
        switch self {
        case .openApp(let name): try Self.validateName(name)
        case .openURL(let url, let browser):
            _ = try Self.webURL(url.absoluteString)
            if let browser { try Self.validateName(browser) }
        case .pressShortcut(let app, _): try Self.validateName(app)
        case .typeText(let app, let text):
            try Self.validateName(app)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= Self.maximumTypedCharacters else {
                throw NativeOpenActionError.invalidArguments("Provide the text to type (up to \(Self.maximumTypedCharacters) characters).")
            }
        }
    }

    static func decode(toolName: String, argumentsJSON: String) throws -> Self {
        try ActionLimits.validateArguments(argumentsJSON)
        guard let object = try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any] else {
            throw NativeOpenActionError.invalidArguments("The open tool requires a JSON object.")
        }
        let action: Self
        switch toolName {
        case "open_app":
            guard Set(object.keys) == ["name"], let name = object["name"] as? String else {
                throw NativeOpenActionError.invalidArguments("open_app requires an app name.")
            }
            action = .openApp(name: name)
        case "open_url":
            guard Set(object.keys).isSubset(of: ["url", "browser"]), let rawURL = object["url"] as? String,
                  object["browser"] == nil || object["browser"] is NSNull || object["browser"] is String else {
                throw NativeOpenActionError.invalidArguments("open_url requires a URL and an optional browser name.")
            }
            let browser = (object["browser"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            action = .openURL(url: try webURL(rawURL), browser: browser?.isEmpty == false ? browser : nil)
        case "press_shortcut":
            guard Set(object.keys) == ["app", "keys"], let app = object["app"] as? String,
                  let keys = object["keys"] as? [String], !keys.isEmpty, keys.count <= 5 else {
                throw NativeOpenActionError.invalidArguments("press_shortcut requires an app name and a keys array.")
            }
            guard let shortcut = KeyboardShortcut(keys: keys) else {
                throw NativeOpenActionError.invalidArguments("Unsupported key combination \(keys). Use modifiers such as cmd or shift plus one key.")
            }
            action = .pressShortcut(app: app, shortcut: shortcut)
        case "type_text":
            guard Set(object.keys) == ["app", "text"], let app = object["app"] as? String, let text = object["text"] as? String else {
                throw NativeOpenActionError.invalidArguments("type_text requires an app name and the text to type.")
            }
            action = .typeText(app: app, text: text)
        default: throw NativeOpenActionError.invalidArguments("Unknown built-in open tool '\(toolName)'.")
        }
        try action.validate()
        return action
    }

    static let webSearchBase = "https://www.google.com/search"

    static func luckySearchURL(for target: String) -> URL? {
        let query = target.replacingOccurrences(of: #"\Athe\s+|\s+(?:website|site|page)\z"#, with: "", options: [.regularExpression, .caseInsensitive])
        guard let url = webSearchURL(for: query), var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems?.append(URLQueryItem(name: "btnI", value: "1"))
        return components.url
    }

    /// A search-engine URL for a spoken query; nil only when the query is empty.
    static func webSearchURL(for query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var components = URLComponents(string: webSearchBase) else { return nil }
        components.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return components.url
    }

    /// The query behind a search URL made by `webSearchURL(for:)`, for readable summaries.
    static func webSearchQuery(from urlString: String) -> String? {
        guard let components = URLComponents(string: urlString), let host = components.host?.lowercased(),
              host == "www.google.com" || host == "google.com", components.path == "/search",
              let query = components.queryItems?.first(where: { $0.name == "q" })?.value?.trimmingCharacters(in: .whitespaces),
              !query.isEmpty else { return nil }
        return query
    }

    static func fastPath(for intent: ActionIntent) -> Self? {
        guard intent.scope != .activeTab else { return nil }
        let goal = intent.goal
        switch intent.action {
        case .openApp:
            guard intent.app != nil, !CommandClauses.hasSequence(goal),
                  let captured = captures(#"\A(?:open(?: up)?|launch|pull up|fire up|start|show me) (.+)\z"#, in: goal)?.first else { return nil }
            let name = CommandLeadIn.stripTrailing(captured)
            guard isPlausibleAppName(name) else { return nil }
            return .openApp(name: name)
        case .switchApp:
            // Opening a running app brings it forward (and restores minimized windows), so a switch
            // is just an open that happens to find the app already running.
            guard intent.app != nil, !CommandClauses.hasSequence(goal),
                  let captured = captures(#"\A(?:switch(?: over)? to|activate|bring up|go to) (.+)\z"#, in: goal)?.first else { return nil }
            let name = CommandLeadIn.stripTrailing(captured)
            guard isPlausibleAppName(name) else { return nil }
            return .openApp(name: name)
        case .webSearch:
            guard let query = intent.query, !query.isEmpty, CommandClauses.split(goal).count <= 1,
                  let url = webSearchURL(for: query) else { return nil }
            return .openURL(url: url, browser: intent.browser)
        case .openURL:
            guard intent.url != nil else { return nil }
            if let parts = captures(#"\Aopen(?: up)? (.+?) and go to (\S+)\z"#, in: goal),
               !CommandClauses.hasSequence(parts[0]), let url = try? webURL(spokenURLToken(parts[1])) {
                return .openURL(url: url, browser: parts[0])
            }
            if let parts = captures(#"\A(?:open(?: up)?|go to) (\S+)(?: in (.+))?\z"#, in: goal),
               let rawURL = parts.first, let url = try? webURL(spokenURLToken(rawURL)) {
                let browser = parts.count > 1 ? parts[1] : nil
                guard !CommandClauses.hasSequence(browser ?? "") else { return nil }
                return .openURL(url: url, browser: browser)
            }
            return nil
        default: return nil
        }
    }

    static func prependingTools(to tools: [ActionToolSpec]) -> [ActionToolSpec] {
        let names = Set(Self.tools.map(\.toolName))
        return Self.tools + tools.filter { $0.serverID != serverID && !names.contains($0.toolName) }
    }

    static func plansWithoutMCP(_ goal: String) -> Bool {
        guard HeuristicIntentExtractor.intent(for: goal).scope != .activeTab else { return false }
        return CommandClauses.split(goal).contains { clause in
            let intent = HeuristicIntentExtractor.intent(for: clause)
            return (intent.scope == nil && [.openApp, .switchApp, .openURL, .webSearch].contains(intent.action))
                || NativeAppRecipe.recipe(for: clause) != nil
                || NativeTypeRecipe.recipe(for: clause) != nil
        }
    }

    static func spokenURLToken(_ token: String) -> String {
        token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’.,!"))
    }

    static func webURL(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = ActionArgumentNormalizer.normalizedURL(trimmed) ?? trimmed
        guard normalized.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let url = URL(string: normalized), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else {
            throw NativeOpenActionError.invalidArguments("Provide a valid http:// or https:// URL.")
        }
        return url
    }

    private static func validateName(_ name: String) throws {
        guard !AppResolver.normalizedName(name).isEmpty, name.count <= 256 else {
            throw NativeOpenActionError.invalidArguments("Provide an installed app or browser name (up to 256 characters).")
        }
    }

    private static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }

    private static func tool(name: String, title: String, description: String, schema: String) -> ActionToolSpec {
        var spec = ActionToolSpec(descriptor: MCPToolDescriptor(serverID: serverID, serverName: "superkeet", name: name,
                                                              title: title, description: description, risk: .mutating, inputSchemaJSON: schema))
        spec.approvalExempt = ["open_app", "open_url", "type_text"].contains(name)
        return spec
    }
}
