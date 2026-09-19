import Foundation

enum ActionIntentFormatter {
    static let maximumLength = 140

    static func summary(toolName: String, argumentsJSON: String) -> String? {
        guard let arguments = parse(argumentsJSON) else { return nil }
        let phrase: String?

        if let command = string(arguments["command_line"]) {
            phrase = "Run: \(command)"
        } else if let argv = arguments["argv"] as? [Any] {
            let parts = argv.compactMap { $0 as? String }
            phrase = parts.isEmpty ? nil : "Run: \(parts.joined(separator: " "))"
        } else if let url = string(arguments["url"]) {
            phrase = string(arguments["browser"]).map { "Open \(url) in \($0)" } ?? "Open \(url)"
        } else if toolName == "open_app", let name = string(arguments["name"]) {
            phrase = "Open \(name)"
        } else if toolName == "press_shortcut", let keys = arguments["keys"] as? [String] {
            let chord = KeyboardShortcut(keys: keys)?.displayName ?? keys.joined(separator: "+")
            phrase = app(arguments).map { "Press \(chord) in \($0)" } ?? "Press \(chord)"
        } else if let text = string(arguments["text"]) {
            phrase = app(arguments).map { "Type “\(clip(text))” in \($0)" } ?? "Type “\(clip(text))”"
        } else if let key = string(arguments["key"]) {
            phrase = "Press \(key)"
        } else if let app = app(arguments), string(arguments["element_index"]) != nil || coordinates(arguments) != nil {
            let target = string(arguments["element_index"]).map { "element \($0)" } ?? coordinates(arguments) ?? "an element"
            phrase = "Click \(target) in \(app)"
        } else if let app = app(arguments) {
            phrase = "\(toolName) in \(app)"
        } else {
            phrase = nil
        }

        guard let result = phrase, !result.isEmpty else { return nil }
        return clip(result)
    }

    private static func parse(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func app(_ arguments: [String: Any]) -> String? {
        string(arguments["app"])
    }

    private static func coordinates(_ arguments: [String: Any]) -> String? {
        guard let x = arguments["x"] as? Double, let y = arguments["y"] as? Double else { return nil }
        return String(format: "(%.0f, %.0f)", x, y)
    }

    private static func clip(_ text: String) -> String {
        let singleLine = text.replacingOccurrences(of: "\n", with: " ")
        guard singleLine.count > maximumLength else { return singleLine }
        return String(singleLine.prefix(maximumLength)) + "…"
    }
}
