import Foundation

/// A compact record of the tool calls a planning session has made so far.
/// When the on-device model's context fills up mid-step, this replaces the
/// full transcript in a fresh session: the model learns what already happened
/// without the bulk of every tool result.
struct ActionProgressSummary: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let toolName: String
        let arguments: String
        let result: String
        let succeeded: Bool
    }

    static let argumentLimit = 120
    static let resultLimit = 160
    static let defaultLimit = 1_200

    private(set) var entries: [Entry] = []

    mutating func record(toolName: String, argumentsJSON: String, result: String) {
        entries.append(Entry(
            toolName: toolName,
            arguments: Self.clip(Self.singleLine(argumentsJSON), to: Self.argumentLimit),
            result: Self.clip(Self.singleLine(result), to: Self.resultLimit),
            succeeded: true
        ))
    }

    mutating func recordFailure(toolName: String, argumentsJSON: String, message: String) {
        entries.append(Entry(
            toolName: toolName,
            arguments: Self.clip(Self.singleLine(argumentsJSON), to: Self.argumentLimit),
            result: Self.clip(Self.singleLine(message), to: Self.resultLimit),
            succeeded: false
        ))
    }

    var isEmpty: Bool { entries.isEmpty }

    /// Instructions text for a continuation session. The newest calls are kept
    /// when the whole list would exceed the limit, because they describe the
    /// current state; older calls are collapsed into a count.
    func instructions(limit: Int = ActionProgressSummary.defaultLimit) -> String {
        guard !entries.isEmpty else { return "" }
        let header = "Your earlier work on this step ran out of room and was condensed. These tool calls already happened; do not repeat them. Continue from here."
        var lines = entries.map { entry in
            "\(entry.succeeded ? "✓" : "✗") \(entry.toolName)(\(entry.arguments)) → \(entry.result)"
        }
        var omitted = 0
        while lines.count > 1, ([header, "(\(omitted) earlier calls omitted)"] + lines).joined(separator: "\n").count > limit {
            lines.removeFirst()
            omitted += 1
        }
        var body = [header]
        if omitted > 0 { body.append("(\(omitted) earlier calls omitted)") }
        return (body + lines).joined(separator: "\n")
    }

    private static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    }

    private static func clip(_ text: String, to limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }
}
