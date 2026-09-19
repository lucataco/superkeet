import Foundation

/// Splits a spoken command into ordered clauses at conjunctions and
/// separators, so each part can be classified on its own. "open Notes and
/// create a new note" yields ["open Notes", "create a new note"]. Separators
/// inside quoted text are left alone, so dictated text such as
/// `type "hello, and goodbye" into Title` stays one clause.
enum CommandClauses {
    private static let separator = try? NSRegularExpression(pattern: #"\b(?:and then|and|then)\b|[;,\n]"#, options: .caseInsensitive)
    private static let quoted = try? NSRegularExpression(
        pattern: #""(?:\\.|[^"\\])*"|“[^”]*”|‘[^’]*’|(?<![\p{L}\p{N}])'[^'\n]*'(?![\p{L}\p{N}])"#
    )

    static func split(_ text: String) -> [String] {
        guard let separator, let quoted else {
            return [text.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }
        }
        let range = NSRange(text.startIndex..., in: text)
        let protected = quoted.matches(in: text, range: range).map(\.range)
        var clauses: [String] = []
        var start = text.startIndex
        for match in separator.matches(in: text, range: range) {
            guard !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                  let cut = Range(match.range, in: text) else { continue }
            clauses.append(String(text[start..<cut.lowerBound]))
            start = cut.upperBound
        }
        clauses.append(String(text[start...]))
        // Trim sentence punctuation only; quotes around dictated text must survive.
        let edges = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;:!?"))
        return clauses
            .map { $0.trimmingCharacters(in: edges) }
            .filter { !$0.isEmpty }
    }
}
