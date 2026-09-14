import Foundation

struct PhraseReplacement: Identifiable, Codable, Equatable {
    var id = UUID()
    var phrase: String
    var replacement: String
    var bundleID: String = ""

    var isValid: Bool {
        !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum TranscriptTextProcessor {
    static func process(
        _ raw: String, removeFillers: Bool, replacements: [PhraseReplacement],
        bundleID: String, spokenCommands: Bool
    ) -> String {
        var text = spokenCommands ? applySpokenCommands(raw) : raw
        text = replacePhrases(text, rules: replacements, bundleID: bundleID)
        if removeFillers { text = FillerWordCleaner.clean(text) }
        return text
    }

    static func replacePhrases(_ text: String, rules: [PhraseReplacement], bundleID: String) -> String {
        let applicable = rules.filter { $0.isValid && ($0.bundleID.isEmpty || $0.bundleID == bundleID) }
            .sorted {
                if $0.bundleID.isEmpty != $1.bundleID.isEmpty { return !$0.bundleID.isEmpty }
                return $0.phrase.count > $1.phrase.count
            }
        var edits: [(NSRange, String)] = []
        for rule in applicable {
            guard let regex = phraseRegex(rule.phrase) else { continue }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            where !edits.contains(where: { NSIntersectionRange($0.0, match.range).length > 0 }) {
                edits.append((match.range, rule.replacement))
            }
        }
        let result = NSMutableString(string: text)
        for (range, replacement) in edits.sorted(by: { $0.0.location > $1.0.location }) {
            result.replaceCharacters(in: range, with: replacement)
        }
        return result as String
    }

    private static func phraseRegex(_ phrase: String) -> NSRegularExpression? {
        try? NSRegularExpression(
            pattern: "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: phrase) + "(?![\\p{L}\\p{N}_])",
            options: .caseInsensitive
        )
    }

    static func applySpokenCommands(_ text: String) -> String {
        guard let clauses = try? NSRegularExpression(pattern: "[^.!?,;\\n]+[.!?,;\\n]*") else { return text }
        let matches = clauses.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var output = ""
        var undo: [String] = []
        var cursor = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            output += text[cursor..<range.lowerBound]
            cursor = range.upperBound
            let clause = String(text[range])
            let command = clause.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!?,;")))
            if command.lowercased() == "undo last correction", let previous = undo.popLast() {
                output = previous
            } else if command.lowercased() == "scratch that", !output.isEmpty {
                let previous = output
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                let sentences = clauses.matches(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed))
                if let last = sentences.last, let lastRange = Range(last.range, in: trimmed) {
                    undo.append(previous)
                    output = String(trimmed[..<lastRange.lowerBound])
                }
            } else if let replacement = replacementCommand(command, in: output) {
                undo.append(output)
                output = replacement
            } else {
                output += clause
            }
        }
        output += text[cursor...]
        return output == text ? text : output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacementCommand(_ command: String, in text: String) -> String? {
        guard command.lowercased().hasPrefix("replace "),
              let phraseStart = command.index(command.startIndex, offsetBy: 8, limitedBy: command.endIndex),
              let separator = command.range(of: " with ", options: .caseInsensitive),
              phraseStart < separator.lowerBound,
              separator.upperBound < command.endIndex else { return nil }
        let phrase = String(command[phraseStart..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
        let replacement = String(command[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !phrase.isEmpty, !replacement.isEmpty, let regex = phraseRegex(phrase) else { return nil }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard matches.count == 1, let match = matches.first, let range = Range(match.range, in: text) else { return nil }
        return text.replacingCharacters(in: range, with: replacement)
    }
}
