import Foundation

/// Recognizes an explicit tab scope before generic "open URL" handling. This
/// supplies routing/slots only; the planner still observes and chooses page IDs.
enum ActiveTabIntent {
    private static let browserPattern = (["google chrome", "microsoft edge"] + ActionIntentPolicy.browsers.sorted())
        .map { NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: " ", with: "\\s+") }
        .joined(separator: "|")
    private static let scopeRegex = try? NSRegularExpression(
        pattern: "\\b(?:(?:in|on|using|use)\\s+)?(?:(?:the|my)\\s+)?"
            + "(?:(\(browserPattern))['’]s\\s+)?(?:active|current)\\s+"
            + "(?:(\(browserPattern)|browser)\\s+)?tab(?:\\s+(?:of|in)\\s+(\(browserPattern)))?\\b",
        options: .caseInsensitive
    )
    private static let quotedText = try? NSRegularExpression(pattern: #""(?:\\.|[^"\\])*"|“[^”]*”|‘[^’]*’|(?<![\p{L}\p{N}])'[^'\n]*'(?![\p{L}\p{N}])"#)

    static func extract(_ goal: String) -> ActionIntent? {
        guard let scopeRegex else { return nil }
        let fullRange = NSRange(goal.startIndex..., in: goal)
        let quotedRanges = quotedText?.matches(in: goal, range: fullRange).map(\.range) ?? []
        guard let match = scopeRegex.matches(in: goal, range: fullRange).first(where: { candidate in
            !quotedRanges.contains { NSIntersectionRange($0, candidate.range).length > 0 }
        }), let range = Range(match.range, in: goal) else { return nil }

        let browsers = (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: goal).map { canonicalBrowser(String(goal[$0])) }
        }.filter { $0 != "browser" }
        let browser = browsers.first { $0 != "chrome" } ?? "chrome"
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",:"))
        var instruction = goal.replacingCharacters(in: range, with: " ").trimmingCharacters(in: separators)
        instruction = instruction.replacingOccurrences(of: #"\A(?:please\s+)?to\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
        let navigation = suffix(
            after: #"\A(?:please\s+)?(?:navigate(?:\s+to)?|open|go\s+to|visit|take\s+me\s+to)\b\s*(.*)\z"#,
            in: instruction
        )
        if let navigation {
            let token = navigation.split(whereSeparator: \.isWhitespace).first.map { NativeOpenAction.spokenURLToken(String($0)) }
            let url = token.flatMap { try? NativeOpenAction.webURL($0).absoluteString }
            return ActionIntent(goal: goal, action: .navigate, browser: browser, url: url, scope: .activeTab)
        }
        let query = suffix(after: #"\A(?:please\s+)?(?:find|search\s+for|look\s+for|locate|read|inspect|summarize|show|check)\b\s*(.*)\z"#,
                           in: instruction) ?? instruction
        return ActionIntent(goal: goal, action: .find, browser: browser, query: query, scope: .activeTab)
    }

    private static func canonicalBrowser(_ name: String) -> String {
        let normalized = name.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        switch normalized {
        case "google chrome": return "chrome"
        case "microsoft edge": return "edge"
        default: return normalized
        }
    }

    private static func suffix(after pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
