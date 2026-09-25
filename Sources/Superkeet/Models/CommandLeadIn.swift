import Foundation

/// Words people say around the actual command: "hey", "please", "let's", "can you", "I want to"
/// before it, "for me", "please", "thanks" after it. The live-speech detector and the intent
/// extractor strip the same sets, so an app launched while the user is still speaking and the
/// command that runs afterwards agree on where the verb starts and where the argument ends.
enum CommandLeadIn {
    static let phrases: [String] = [
        "hey", "hi", "ok", "okay", "alright", "all right", "yeah", "yes", "please", "um", "uh", "so", "now", "just",
        "and", "also", "then", "next", "after that", "once you're there", "once you’re there", "once you are there",
        "when you're there", "when you’re there", "when you are there", "from there", "in there",
        "superkeet", "let's", "let’s", "lets", "let us", "go ahead and", "can you", "could you", "would you", "will you",
        "i want to", "i need to", "i'd like to", "i’d like to", "i would like to", "i want you to", "i need you to"
    ]

    /// Politeness and hesitation people append after the command; never part of an argument.
    static let trailingPhrases: [String] = [
        "for me", "for us", "please", "thanks", "thank you", "ah", "uh", "um", "okay", "ok", "alright", "all right",
        "now", "real quick", "really quick", "quickly", "if you can", "if you could", "when you can", "right now",
        "if you don't mind", "if you don’t mind",
        // A connector the speaker trailed off on: "open the Chrome browser. And" names Chrome.
        "and then", "and also", "and", "also", "then", "so"
    ]

    /// An utterance made only of these words is a reaction to what just happened, not a command:
    /// "Great. Great. Okay. Let's move on." runs nothing.
    static let acknowledgementWords: Set<String> = [
        "great", "nice", "cool", "awesome", "perfect", "good", "okay", "ok", "alright", "all", "right", "thanks", "thank",
        "you", "yes", "yeah", "yep", "yup", "no", "nope", "hmm", "hm", "um", "uh", "ah", "oh", "wow", "sweet", "excellent",
        "amazing", "let's", "let’s", "lets", "move", "on", "that's", "that’s", "thats", "it", "works", "worked", "done",
        "sure", "fine", "job", "well", "very", "so", "now", "and", "then", "next", "never", "mind", "nevermind", "please",
        "superkeet", "cheers", "hello", "hey", "hi", "that", "this", "is", "was", "it's", "it’s"
    ]

    /// Verbs that make a clause an instruction even when it opens with a preposition ("on the
    /// second line write hello"). Deliberately short: common nouns such as "new" or "set" are out.
    static let strongVerbs: Set<String> = [
        "open", "launch", "click", "type", "write", "press", "search", "google", "go", "create", "make", "save", "close",
        "quit", "scroll", "delete", "send", "play", "pause", "take", "enter", "put", "insert", "switch", "navigate", "visit",
        "look", "find", "read", "summarize", "summarise", "tell", "ask", "select", "copy", "paste", "undo", "redo", "run",
        "start", "stop", "add", "remove", "reply", "compose", "draft", "email", "message", "call", "download", "install"
    ]

    private static let pattern: NSRegularExpression? = {
        let alternatives = phrases
            .sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: " ", with: "\\s+") }
            .joined(separator: "|")
        return try? NSRegularExpression(pattern: "\\A(?:(?:\(alternatives))\\b[,\\s]*)+", options: .caseInsensitive)
    }()

    private static let trailingPattern: NSRegularExpression? = {
        let alternatives = trailingPhrases
            .sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: " ", with: "\\s+") }
            .joined(separator: "|")
        return try? NSRegularExpression(pattern: "(?:[,.;:\\s]+(?:\(alternatives))\\b[.!?,\\s]*)+\\z", options: .caseInsensitive)
    }()

    private static let contextPattern = try? NSRegularExpression(
        pattern: #"\A(?:in|inside|into|on|at|from|within|once|when|after|before|there|here|now that)\b"#,
        options: .caseInsensitive
    )

    /// Removes leading filler and returns the remainder with its original casing.
    static func strip(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pattern,
              let match = pattern.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              match.range.length > 0,
              let range = Range(match.range, in: trimmed) else { return trimmed }
        return String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes trailing filler ("open Notes for me, please." becomes "open Notes"). Only applied to
    /// arguments that name things, never to text the user wants typed.
    static func stripTrailing(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trailingPattern,
              let match = trailingPattern.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              match.range.length > 0,
              let range = Range(match.range, in: trimmed) else { return trimmed }
        return String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let trailingReactionPattern = try? NSRegularExpression(
        pattern: #"(?:[,.;:!?\s]+(?:nice|great|cool|awesome|perfect|sweet|excellent|amazing|wow|thanks|thank\s+you))+[.!?,\s]*\z"#,
        options: .caseInsensitive
    )

    /// Removes reactions the recogniser glued onto the end of a command when the speaker didn't
    /// pause: "open up x.com Nice, nice." becomes "open up x.com". Only for commands that name
    /// something to open; typed text keeps every word.
    static func stripTrailingReactions(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trailingReactionPattern,
              let match = trailingReactionPattern.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              match.range.length > 0,
              let range = Range(match.range, in: trimmed) else { return trimmed }
        return String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Leading and trailing filler removed.
    static func trim(_ text: String) -> String {
        stripTrailing(strip(text))
    }

    /// Whether the text is only a reaction ("Cool. Awesome. Thank you.") or empty.
    static func isAcknowledgement(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter && $0 != "'" && $0 != "’" }.map(String.init)
        guard !words.isEmpty else { return true }
        return words.allSatisfy { acknowledgementWords.contains($0) }
    }

    /// Whether a clause only situates the next one ("inside this new note", "once you're there")
    /// without asking for anything itself: it opens with a preposition, stays short, and contains
    /// no instruction verb.
    static func isContextOnly(_ clause: String) -> Bool {
        let stripped = strip(clause)
        guard !stripped.isEmpty, let contextPattern,
              contextPattern.firstMatch(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)) != nil else { return false }
        let words = stripped.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" }.map(String.init)
        guard words.count <= 6 else { return false }
        return !words.contains { strongVerbs.contains($0) }
    }
}
