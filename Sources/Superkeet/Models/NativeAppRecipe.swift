import Foundation

struct NativeAppRecipe: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        case named(String)
        case current
    }

    let shortcut: KeyboardShortcut
    let target: Target
    let description: String

    private struct Rule: @unchecked Sendable {
        let pattern: NSRegularExpression
        let keys: [String]
        let description: @Sendable (NSTextCheckingResult, String) -> String
    }

    private static let rules: [Rule] = ([
        rule(#"\A(?:create|make|start|add|compose|write|open)\s+(?:a\s+|an\s+)?(?:brand\s+)?new\s+(tab)\b"#, ["cmd", "t"]) { _, _ in "open a new tab" },
        rule(#"\A(?:create|make|start|add|compose|write)\s+(?:a\s+|an\s+)?(?:brand\s+)?new\s+(?:one|item|entry)\b"#, ["cmd", "n"]) { _, _ in "create a new item" },
        rule(#"\A(?:create|make|start|add|compose|write|open)\s+(?:a\s+|an\s+)?(?:brand\s+)?new\s+([a-z][a-z ]*?)(?=\s+(?:in|into|inside|with|using)\b|\z)"#, ["cmd", "n"]) { match, text in
            "create a new \(Self.capture(match, 1, in: text) ?? "document")"
        },
        rule(#"\Anew\s+(tab)\b"#, ["cmd", "t"]) { _, _ in "open a new tab" },
        rule(#"\Anew\s+([a-z][a-z ]*?)(?=\s+(?:in|into|inside)\b|\z)"#, ["cmd", "n"]) { match, text in "create a new \(Self.capture(match, 1, in: text) ?? "document")" },
        rule(#"\Asave(?:\s+(?:it|this|that|the\s+(?:note|file|document|changes?)))?(?=\s+(?:in|into)\b|\z)"#, ["cmd", "s"]) { _, _ in "save" },
        rule(#"\Aclose\s+(?:(?:the\s+|this\s+)?(?:tab))(?=\s+(?:in)\b|\z)"#, ["cmd", "w"]) { _, _ in "close the tab" },
        rule(#"\Aclose(?:\s+(?:it|this|that|the\s+(?:window|note|file|document)))?(?=\s+(?:in)\b|\z)"#, ["cmd", "w"]) { _, _ in "close the window" },
        rule(#"\Aundo(?:\s+(?:that|it|this|the\s+last\s+(?:change|edit|action)))?(?=\s+(?:in)\b|\z)"#, ["cmd", "z"]) { _, _ in "undo" },
        rule(#"\Aredo(?:\s+(?:that|it|this))?(?=\s+(?:in)\b|\z)"#, ["cmd", "shift", "z"]) { _, _ in "redo" },
        rule(#"\Aselect\s+all(?:\s+(?:the\s+)?text)?(?=\s+(?:in)\b|\z)"#, ["cmd", "a"]) { _, _ in "select all" },
        rule(#"\Aquit(?:\s+(?:it|this|that|the\s+app))?(?=\s+(?:in)\b|\z)"#, ["cmd", "q"]) { _, _ in "quit" }
    ] as [Rule?]).compactMap { $0 }

    private static let trailingTarget = try? NSRegularExpression(
        pattern: #"\s+(?:in|into|inside|with|using)\s+(?:the\s+)?(.+?)\s*\z"#, options: .caseInsensitive
    )

    static func recipe(for clause: String) -> NativeAppRecipe? {
        var text = clause.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;:!?")))
        text = text.replacingOccurrences(of: #"\A(?:please\s+|now\s+|then\s+|also\s+)+"#, with: "", options: .regularExpression)
        guard !text.isEmpty else { return nil }

        var target = Target.current
        if let trailingTarget, let match = trailingTarget.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range, in: text), let name = capture(match, 1, in: text) {
            target = .named(name)
            text = String(text[..<range.lowerBound])
        }

        for rule in rules {
            guard let match = rule.pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let shortcut = KeyboardShortcut(keys: rule.keys) else { continue }
            return NativeAppRecipe(shortcut: shortcut, target: target, description: rule.description(match, text))
        }

        if let match = try? NSRegularExpression(pattern: #"\Aquit\s+(?:the\s+)?([a-z][a-z0-9 ]*?)(?:\s+app)?\z"#)
            .firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let name = capture(match, 1, in: text), !["it", "this", "that"].contains(name),
           let shortcut = KeyboardShortcut(keys: ["cmd", "q"]) {
            return NativeAppRecipe(shortcut: shortcut, target: .named(name), description: "quit")
        }
        return nil
    }

    static var ruleCount: Int { rules.count }
    static let expectedRuleCount = 12

    private static func rule(_ pattern: String, _ keys: [String], description: @escaping @Sendable (NSTextCheckingResult, String) -> String) -> Rule? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return Rule(pattern: regex, keys: keys, description: description)
    }

    private static func capture(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> String? {
        guard index < match.numberOfRanges, let range = Range(match.range(at: index), in: text) else { return nil }
        let value = String(text[range]).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}
