import Foundation

struct NativeTypeRecipe: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        case named(String)
        case current
    }

    let text: String
    let target: Target
    let fullText: String

    init(text: String, target: Target, fullText: String? = nil) {
        self.text = text
        self.target = target
        self.fullText = fullText ?? text
    }

    static let patterns: [NSRegularExpression] = [
        #"\A(?:type|write|enter|input|put|insert|dictate|jot)(?:\s+(?:in|out|down))?\s+(?:the\s+(?:text|words?|phrase|following)\s+)?(?:that\s+says\s+)?(.+)\z"#,
        #"\A(?:make|have|let)\s+(?:the\s+|this\s+|that\s+|its\s+|it\s+)?(?:new\s+)?(?:title|heading|header|headline|name|subject|note|text|body|first\s+line|line|field|document|it|this|that)?\s*(?:say|read|be|show|contain)\s+(.+)\z"#,
        #"\A(?:set|change|update)\s+(?:the\s+|its\s+)?(?:title|heading|header|headline|name|subject|text|body|first\s+line)\s+to\s+(.+)\z"#,
        #"\A(?:name|title|call)\s+(?:it|this|the\s+(?:note|document|file))\s+(.+)\z"#
    ].compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }

    private static let trailingTarget = try? NSRegularExpression(
        pattern: #"\s+(?:in|into|inside)\s+(?:the\s+)?([A-Za-z][A-Za-z0-9 .'’-]*?)(?:\s+app)?\s*\z"#, options: .caseInsensitive
    )

    static func recipe(for clause: String) -> NativeTypeRecipe? {
        guard NativeAppRecipe.recipe(for: clause) == nil else { return nil }
        let stripped = CommandLeadIn.strip(clause)
        guard !stripped.isEmpty else { return nil }
        for pattern in patterns {
            guard let match = pattern.firstMatch(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)),
                  let range = Range(match.range(at: 1), in: stripped) else { continue }
            var text = String(stripped[range])
            let fullText = unquoted(text)
            var target = Target.current
            if let trailingTarget,
               let trailing = trailingTarget.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let wholeRange = Range(trailing.range, in: text), let nameRange = Range(trailing.range(at: 1), in: text) {
                target = .named(String(text[nameRange]).trimmingCharacters(in: .whitespaces))
                text = String(text[..<wholeRange.lowerBound])
            }
            text = unquoted(text)
            guard !text.isEmpty else { return nil }
            return NativeTypeRecipe(text: text, target: target, fullText: fullText)
        }
        return nil
    }

    static func unquoted(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let quotes: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("‘", "’"), ("'", "'")]
        for (open, close) in quotes where value.count >= 2 && value.first == open && value.last == close {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if value.hasSuffix(".") && !value.hasSuffix("...") { value.removeLast() }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
