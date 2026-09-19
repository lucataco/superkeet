import Foundation

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
        let edges = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;:!?"))
        return clauses
            .map { $0.trimmingCharacters(in: edges) }
            .filter { !$0.isEmpty }
    }

    static func hasSequence(_ text: String) -> Bool {
        text.range(of: #"\b(and|then|after|before)\b|[;\n]"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
