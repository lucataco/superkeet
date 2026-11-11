import Foundation

/// What a spoken clause asks for, as read by a router that understands meaning rather than
/// matching phrasings. The native routes recognise "open Notes"; a router also places "I need
/// the calculator" and "jump back over to TextEdit".
///
/// A router only says what kind of request it is and which words it is about. Turning that
/// into an action, and deciding whether those words can be trusted, is `RoutedIntentResolver`.
struct RoutedIntent: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case openApp = "open_app"
        case openWebsite = "open_website"
        case webSearch = "web_search"
        case newItem = "new_item"
        case newTab = "new_tab"
        case typeText = "type_text"
        case save
        case close
        case undo
        case redo
        case selectAll = "select_all"
        case quit
        /// A real request that the built-in actions cannot carry out.
        case other
        /// Not a request: an acknowledgement, thinking aloud, or talk meant for someone else.
        case nothing

        /// One line a model can choose by. Kept short: every word is read on every clause.
        var meaning: String {
            switch self {
            case .openApp: return "open, show, bring up or switch to an application"
            case .openWebsite: return "go to a named website or web address"
            case .webSearch: return "search the web for something"
            case .newItem: return "make a new, fresh or blank document, note, window, message or other item"
            case .newTab: return "open a new browser tab"
            case .typeText: return "type, write or dictate given words, or set a title or heading to given words"
            case .save: return "save the current document"
            case .close: return "close the current window or tab"
            case .undo: return "undo the last change"
            case .redo: return "redo the change that was undone"
            case .selectAll: return "select everything"
            case .quit: return "quit the current application"
            case .other: return "anything else: clicking, reading the screen, a question, a task with several parts"
            case .nothing: return "not a request: an acknowledgement, filler, thinking aloud, or talk to someone else"
            }
        }

        /// What the argument is, for the kinds that have one.
        var argumentMeaning: String? {
            switch self {
            case .openApp: return "the application's name"
            case .openWebsite: return "the site's name or address, in the speaker's words"
            case .webSearch: return "what to search for, in the speaker's words"
            case .typeText: return "exactly the words to type, in the speaker's words"
            default: return nil
            }
        }

        var shortcutKeys: [String]? {
            switch self {
            case .newItem: return ["cmd", "n"]
            case .newTab: return ["cmd", "t"]
            case .save: return ["cmd", "s"]
            case .close: return ["cmd", "w"]
            case .undo: return ["cmd", "z"]
            case .redo: return ["cmd", "shift", "z"]
            case .selectAll: return ["cmd", "a"]
            case .quit: return ["cmd", "q"]
            default: return nil
            }
        }
    }

    let kind: Kind
    let argument: String?

    init(kind: Kind, argument: String? = nil) {
        self.kind = kind
        let trimmed = argument?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.argument = trimmed?.isEmpty == false ? trimmed : nil
    }
}

/// Reads a clause the native routes did not recognise. Returns nil when it cannot tell, and the
/// clause then goes to the planner as before.
@MainActor
protocol IntentRouting: AnyObject {
    func route(_ clause: String, currentApp: String?) async -> RoutedIntent?
    /// Called when a command starts being spoken, so a model is loaded before it is needed.
    func prewarm()
}

extension IntentRouting {
    func prewarm() {}
}

enum RoutedIntentResolution: Equatable {
    case action(NativeOpenAction)
    /// The clause asks for nothing; it is dropped like an acknowledgement.
    case nothing
    /// Not something a built-in action can do, or the router's words could not be trusted.
    case unresolved
}

/// Turns a router's reading into a built-in action, or declines.
///
/// A model can be wrong, so its words are only used when the speaker said them. Text to type, a
/// search and a site must appear in the clause; the action then runs on the speaker's own words,
/// exactly as a native route would. An app name need not be spoken ("check my email" is Mail),
/// because opening an installed app is harmless and runs without asking already.
enum RoutedIntentResolver {
    static func resolve(_ intent: RoutedIntent, clause: String, context: NativeClauseContext) -> RoutedIntentResolution {
        switch intent.kind {
        case .nothing:
            return .nothing
        case .other:
            return .unresolved
        case .openApp:
            guard let url = installedApp(named: intent.argument, context: context) else { return .unresolved }
            return .action(.openApp(name: url.deletingPathExtension().lastPathComponent))
        case .openWebsite:
            guard let spoken = spokenWords(intent.argument, in: clause).map(CommandLeadIn.stripTrailing), !spoken.isEmpty,
                  !startsTheRequest(spoken, in: clause) else { return .unresolved }
            return website(spoken, context: context).map(RoutedIntentResolution.action) ?? .unresolved
        case .webSearch:
            // "for me" and "please" are dropped from a search, as the native routes do; never from typed text.
            guard let query = spokenWords(intent.argument, in: clause).map(CommandLeadIn.stripTrailing),
                  !startsTheRequest(query, in: clause), let url = NativeOpenAction.webSearchURL(for: query) else { return .unresolved }
            return .action(.openURL(url: url, browser: browser(in: context)))
        case .typeText:
            guard let text = spokenWords(intent.argument, in: clause), let app = context.currentApp,
                  !startsTheRequest(text, in: clause) else { return .unresolved }
            return .action(.typeText(app: app, text: text))
        case .newItem, .newTab, .save, .close, .undo, .redo, .selectAll, .quit:
            guard let keys = intent.kind.shortcutKeys, let shortcut = KeyboardShortcut(keys: keys),
                  let app = context.currentApp else { return .unresolved }
            return .action(.pressShortcut(app: app, shortcut: shortcut))
        }
    }

    /// The app a router's words name. A router that can only point at where the name starts
    /// returns the rest of the sentence with it ("Spotify to the front", "the calculator for
    /// me"), so the longest leading run of words that names an installed app wins.
    private static func installedApp(named argument: String?, context: NativeClauseContext) -> URL? {
        guard let argument else { return nil }
        let parts = argument.split(whereSeparator: \.isWhitespace)
        for count in stride(from: min(parts.count, NativeOpenAction.maximumAppNameWords), through: 1, by: -1) {
            let name = parts.prefix(count).joined(separator: " ")
            if NativeOpenAction.isPlausibleAppName(name), let url = context.resolveApp(name) { return url }
        }
        return nil
    }

    private static func browser(in context: NativeClauseContext) -> String? {
        context.currentApp.flatMap { ActionIntentPolicy.isBrowserName($0) ? $0 : nil }
    }

    private static func website(_ spoken: String, context: NativeClauseContext) -> NativeOpenAction? {
        let address = NativeOpenAction.spokenURLToken(SpokenURL.normalize(spoken))
        if address.contains("."), let url = try? NativeOpenAction.webURL(address) {
            return .openURL(url: url, browser: browser(in: context))
        }
        return NativeOpenAction.luckySearchURL(for: spoken).map { .openURL(url: $0, browser: browser(in: context)) }
    }

    /// A request always has words that ask before the words it is about ("jot down …", "the
    /// title should be …", "look up …", "take me to …"). Words that begin where the request
    /// begins are the request itself, which a small model returns when it cannot tell the two
    /// apart: it offered to search the web for "Summarize this page".
    static func startsTheRequest(_ text: String, in clause: String) -> Bool {
        let request = words(in: CommandLeadIn.strip(clause)).map(\.key)
        let typed = words(in: text).map(\.key)
        return !typed.isEmpty && Array(request.prefix(typed.count)) == typed
    }

    /// The stretch of the clause the router's argument names, in the speaker's own spelling, or
    /// nil when the speaker did not say it. Case, punctuation and spacing are ignored; the words
    /// and their order are not.
    static func spokenWords(_ argument: String?, in clause: String) -> String? {
        guard let argument else { return nil }
        let wanted = words(in: argument).map(\.key)
        let said = words(in: clause)
        guard !wanted.isEmpty, wanted.count <= said.count else { return nil }
        for start in 0...(said.count - wanted.count) where said[start..<(start + wanted.count)].map(\.key) == wanted {
            let first = said[start].range.lowerBound
            let last = said[start + wanted.count - 1].range.upperBound
            return String(clause[first..<last])
        }
        return nil
    }

    /// Words with their place in the text. Inner apostrophes, hyphens and dots stay part of a
    /// word, so "don't", "x.com" and "follow-up" are each one.
    private static func words(in text: String) -> [(key: String, range: Range<String.Index>)] {
        var result: [(key: String, range: Range<String.Index>)] = []
        var start: String.Index?
        var index = text.startIndex
        func close(at end: String.Index) {
            guard let begin = start else { return }
            var upper = end
            while upper > begin, !isWordCharacter(text[text.index(before: upper)]) { upper = text.index(before: upper) }
            if upper > begin {
                let word = String(text[begin..<upper])
                result.append((key: word.lowercased().replacingOccurrences(of: "’", with: "'"), range: begin..<upper))
            }
            start = nil
        }
        while index < text.endIndex {
            let character = text[index]
            if isWordCharacter(character) {
                if start == nil { start = index }
            } else if start != nil, !isJoiner(character) {
                close(at: index)
            }
            index = text.index(after: index)
        }
        close(at: text.endIndex)
        return result
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    private static func isJoiner(_ character: Character) -> Bool {
        "'’-./:".contains(character)
    }
}
