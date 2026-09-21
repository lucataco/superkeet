import Foundation

/// Spoken steps that mean "type this text": "type hello", "write hello world", "make the title
/// say hello", "set the heading to Groceries", optionally ending in "in Notes". They resolve to
/// the built-in `type_text` tool, so the most common in-app step never needs a model.
struct NativeTypeRecipe: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        case named(String)
        case current
    }

    /// The words to type, without the trailing "in Notes" that named the target.
    let text: String
    let target: Target
    /// The words including the trailing phrase, for when the named target turns out not to be an
    /// app ("type restaurants in Paris") and the phrase was part of the text after all.
    let fullText: String

    init(text: String, target: Target, fullText: String? = nil) {
        self.text = text
        self.target = target
        self.fullText = fullText ?? text
    }

    static let patterns: [NSRegularExpression] = [
        // type hello · write "hello world" · enter hello · type in hello · write down hello · put hello
        #"\A(?:type|write|enter|input|put|insert|dictate|jot)(?:\s+(?:in|out|down))?\s+(?:the\s+(?:text|words?|phrase|following)\s+)?(?:that\s+says\s+)?(.+)\z"#,
        // make the title say hello · have it say hello · let the note read hello · make it be hello
        #"\A(?:make|have|let)\s+(?:the\s+|this\s+|that\s+|its\s+|it\s+)?(?:new\s+)?(?:title|heading|header|headline|name|subject|note|text|body|first\s+line|line|field|document|it|this|that)?\s*(?:say|read|be|show|contain)\s+(.+)\z"#,
        // set the title to hello · change the heading to hello
        #"\A(?:set|change|update)\s+(?:the\s+|its\s+)?(?:title|heading|header|headline|name|subject|text|body|first\s+line)\s+to\s+(.+)\z"#,
        // name it hello · title it hello · call the note hello
        #"\A(?:name|title|call)\s+(?:it|this|the\s+(?:note|document|file))\s+(.+)\z"#
    ].compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }

    private static let trailingTarget = try? NSRegularExpression(
        pattern: #"\s+(?:in|into|inside)\s+(?:the\s+)?([A-Za-z][A-Za-z0-9 .'’-]*?)(?:\s+app)?\s*\z"#, options: .caseInsensitive
    )

    static func recipe(for clause: String) -> NativeTypeRecipe? {
        // "write a new note" is ⌘N, never typed text; the shortcut table wins.
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

    /// Drops surrounding quotes and the sentence-final period the recogniser adds; other
    /// punctuation is kept because the user may have meant it.
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
