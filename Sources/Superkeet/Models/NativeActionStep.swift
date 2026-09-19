import Foundation
import CoreFoundation

/// A single supplied instruction. The grounder never extracts slots or plans tasks.
struct NativeActionStep: Equatable, Sendable {
    enum Operation: String, Sendable { case click, setText }
    let operation: Operation
    let app: String
    let target: String
    let text: String?

    var goal: String {
        operation == .click ? "Click \(target)." : "Type \(NativeGroundingJSON.quote(text ?? "")) into \(target)."
    }

    var key: String {
        [operation.rawValue, app.lowercased(), target.lowercased(), text ?? ""].map(NativeGroundingJSON.quote).joined()
    }

    /// Only unambiguous literal templates bypass the broader Foundation Models planner.
    static func literal(_ task: String) -> Self? {
        if let parts = captures(#"^click (.+) in ([^\n]+?)[.]?$"#, in: task),
           !hasSequence(parts.joined(separator: " ")) {
            return Self(operation: .click, app: parts[1], target: parts[0], text: nil)
        }
        if let parts = captures(#"^type ["“]([^"”]*)["”] into (.+) in ([^\n]+?)[.]?$"#, in: task),
           !hasSequence(parts[1] + " " + parts[2]) {
            return Self(operation: .setText, app: parts[2], target: parts[1], text: parts[0])
        }
        return nil
    }

    static func decode(_ json: String, operation: Operation) throws -> Self {
        let object = try NativeGroundingJSON.object(json)
        let keys: Set<String> = operation == .click ? ["app", "target"] : ["app", "target", "text"]
        guard Set(object.keys) == keys, let app = object["app"] as? String,
              let target = object["target"] as? String else {
            throw ActionChoiceError.invalid("supply one app, target, and the exact text for text entry")
        }
        let step = Self(operation: operation, app: app, target: target, text: object["text"] as? String)
        try step.validate()
        return step
    }

    func validate() throws {
        guard !app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, app.count <= 200,
              !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, target.count <= 400,
              operation != .setText || (text != nil && (text?.count ?? 0) <= 400) else {
            throw ActionChoiceError.invalid("the single-step app, target, or text is missing or too long")
        }
    }

    static func hasSequence(_ text: String) -> Bool {
        text.range(of: #"\b(and|then|after|before)\b|[;\n]"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }
}

enum NativeGroundingJSON {
    static let maximumObservationBytes = 1_048_576

    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int(exactly: number)
    }

    static func object(_ json: String) throws -> [String: Any] {
        guard json.utf8.count <= maximumObservationBytes,
              let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw ActionChoiceError.invalid("missing or oversized structured Driver result")
        }
        guard object["status"] as? String != "refused", object["effect"] as? String != "refused",
              object["refusal"] == nil || object["refusal"] is NSNull else {
            throw ActionChoiceError.invalid("Cua Driver refused the action; it will not be retried")
        }
        return object
    }

    static func encode(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else { throw ActionChoiceError.invalid("invalid JSON encoding") }
        return text
    }

    static func quote(_ text: String) -> String {
        (try? JSONEncoder().encode(text)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }
}
