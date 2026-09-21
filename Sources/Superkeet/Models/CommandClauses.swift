import Foundation

enum CommandClauses {
    /// Conjunctions, punctuation, and sentence ends. Parakeet punctuates, so "Open Discord. Open
    /// Notes." arrives as two sentences; a period only counts when whitespace or the end follows
    /// it, which keeps "youtube.com" and "3.5" intact.
    private static let separator = try? NSRegularExpression(pattern: #"\b(?:and then|and|then)\b|[;,\n]|[.?!](?=\s|\z)"#, options: .caseInsensitive)
    private static let quoted = try? NSRegularExpression(
        pattern: #""(?:\\.|[^"\\])*"|“[^”]*”|‘[^’]*’|(?<![\p{L}\p{N}])'[^'\n]*'(?![\p{L}\p{N}])"#
    )
    private static let separatorOnly = try? NSRegularExpression(pattern: #"\A(?:(?:and|then)\b[,\s]*)+\z"#, options: .caseInsensitive)

    /// Verbs a new step can start with. A bare "and" or a comma only splits the command when the
    /// words after it begin a new instruction, so "search for Morgan Freeman and Tom Hanks" stays
    /// one step while "open Notes and create a new note" becomes two.
    static let clauseVerbs: [String] = [
        "open", "launch", "pull up", "fire up", "bring up", "start", "show me", "switch to", "switch over to", "activate",
        "go to", "navigate to", "visit", "search", "google", "look up", "lookup", "find", "click", "tap", "double click",
        "double-click", "right click", "right-click", "type", "enter", "press", "hit", "scroll", "swipe", "drag", "read",
        "create", "make", "add", "compose", "write", "new", "save", "close", "quit", "exit", "kill", "undo", "redo", "select",
        "copy", "paste", "cut", "delete", "remove", "clear", "send", "reply", "forward", "play", "pause", "stop", "mute",
        "unmute", "set", "turn", "enable", "disable", "toggle", "take", "screenshot", "run", "execute", "check", "tell",
        "summarize", "summarise", "translate", "ask", "show", "hide", "minimize", "minimise", "maximize", "maximise", "zoom",
        "resize", "move", "focus", "refresh", "reload", "sign", "log", "download", "upload", "install", "print", "share",
        "draft", "email", "message", "call", "schedule", "book", "order", "buy", "pay", "browse", "watch", "listen",
        "calculate", "convert", "rename", "edit", "update", "change", "sort", "filter", "export", "import", "attach",
        "insert", "format", "highlight", "archive", "pin", "star", "follow", "subscribe", "join", "leave", "invite",
        "accept", "decline", "dismiss", "snooze", "remind", "record", "capture", "search for", "look for", "wait",
        "do a search", "do a google search", "do a web search", "run a search", "perform a search"
    ]

    private static let clauseStart: NSRegularExpression? = {
        let alternatives = clauseVerbs
            .sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: " ", with: "\\s+") }
            .joined(separator: "|")
        return try? NSRegularExpression(pattern: "\\A(?:then\\b[,\\s]*)?(?:\(alternatives))\\b", options: .caseInsensitive)
    }()

    static func split(_ text: String) -> [String] {
        guard let separator, let quoted else {
            return [text.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }
        }
        let range = NSRange(text.startIndex..., in: text)
        let protected = quoted.matches(in: text, range: range).map(\.range)
        let matches = separator.matches(in: text, range: range).filter { match in
            !protected.contains { NSIntersectionRange($0, match.range).length > 0 }
        }
        var clauses: [String] = []
        var start = text.startIndex
        for (offset, match) in matches.enumerated() {
            guard let cut = Range(match.range, in: text) else { continue }
            let token = text[cut].lowercased()
            let remainder = String(text[cut.upperBound...])
            let segmentEnd = matches.dropFirst(offset + 1).first.flatMap { Range($0.range, in: text)?.lowerBound } ?? text.endIndex
            let nextSegment = String(text[cut.upperBound..<segmentEnd])
            let sequencing = token.contains("then") || token == ";" || token == "\n"
            // Any separator also splits when only filler follows it ("open Notes. Ah.", "create a
            // new note and inside this new note, …") so the filler never pollutes the argument
            // before it and is dropped on its own. "search for Dr. Smith" stays whole because
            // "Smith" is neither an instruction nor filler.
            guard sequencing || startsClause(remainder) || isDroppable(nextSegment) || isDroppable(remainder) else { continue }
            clauses.append(String(text[start..<cut.lowerBound]))
            start = cut.upperBound
        }
        clauses.append(String(text[start...]))
        return clauses
            .map { $0.trimmingCharacters(in: edges) }
            .filter { !$0.isEmpty && !isSeparatorOnly($0) && !isDroppable($0) }
    }

    private static let edges = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;:!?"))

    private static let trailingConjunction = try? NSRegularExpression(
        pattern: #"[,\s]*\b(?:and then|and|then)\b[,\s]*\z"#, options: .caseInsensitive
    )

    /// "open Notes and" → ("open Notes", true): a conjunction with nothing after it yet means
    /// the speaker has finished that clause and moved on. Only conjunctions count; a period from
    /// the recogniser can be tentative while the sentence is still going.
    static func strippingTrailingConjunction(_ text: String) -> (text: String, movedOn: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trailingConjunction,
              let match = trailingConjunction.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              match.range.length > 0, let range = Range(match.range, in: trimmed) else { return (trimmed, false) }
        return (String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines), true)
    }

    /// Acknowledgements ("Great. Okay."), bare lead-ins ("and once you're there"), and context
    /// phrases ("inside this new note") carry no instruction of their own and are dropped rather
    /// than sent to the planner.
    static func isDroppable(_ clause: String) -> Bool {
        let trimmed = clause.trimmingCharacters(in: edges)
        guard !trimmed.isEmpty else { return false }
        let stripped = CommandLeadIn.strip(trimmed)
        return stripped.isEmpty || CommandLeadIn.isAcknowledgement(stripped) || CommandLeadIn.isContextOnly(stripped)
    }

    /// Whether the text reads as the beginning of a new instruction: a known verb after any
    /// lead-in words, or a web address.
    static func startsClause(_ remainder: String) -> Bool {
        let stripped = SpokenURL.normalize(CommandLeadIn.strip(remainder))
        guard !stripped.isEmpty else { return false }
        if let clauseStart, clauseStart.firstMatch(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)) != nil {
            return true
        }
        guard let first = stripped.split(whereSeparator: \.isWhitespace).first else { return false }
        let token = NativeOpenAction.spokenURLToken(String(first))
        return token.hasPrefix("http://") || token.hasPrefix("https://") || ActionArgumentNormalizer.normalizedURL(token) != nil
    }

    static func hasSequence(_ text: String) -> Bool {
        if split(text).count > 1 { return true }
        return text.range(of: #"\b(then|after|before)\b|[;\n]"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func isSeparatorOnly(_ clause: String) -> Bool {
        guard let separatorOnly else { return false }
        return separatorOnly.firstMatch(in: clause, range: NSRange(clause.startIndex..., in: clause)) != nil
    }
}
