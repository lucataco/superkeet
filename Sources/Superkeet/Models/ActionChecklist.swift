import Foundation

struct ActionChecklist: Equatable, Sendable {
    private(set) var lines: [ActionLine] = []
    private(set) var replies: [String] = []
    private var open: Int?

    var isEmpty: Bool { lines.isEmpty }

    var hasFailedLine: Bool {
        lines.contains { line in
            if case .failed = line.status { return true }
            return false
        }
    }

    var failureTitle: String {
        hasFailedLine ? "One step didn’t work" : "Couldn’t finish"
    }

    enum Outcome: Equatable, Sendable {
        case succeeded
        case failed(message: String)
        case cancelled
    }

    /// Returns the new line's position, for `retitle(line:to:)`.
    @discardableResult
    mutating func addDone(_ title: String) -> Int {
        lines.append(ActionLine(status: .done, title: title))
        return lines.count - 1
    }

    mutating func retitle(line index: Int, to title: String) {
        guard lines.indices.contains(index) else { return }
        lines[index].title = title
    }

    mutating func setOpenLine(_ title: String) {
        let line = ActionLine(status: .running, title: title)
        if let open {
            lines[open] = line
        } else {
            lines.append(line)
            open = lines.count - 1
        }
    }

    mutating func settleOpenLine(title: String? = nil) {
        if let open {
            if let title { lines[open].title = title }
            if lines[open].status == .running { lines[open].status = .done }
        }
        open = nil
    }

    mutating func addReply(_ reply: String) {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { replies.append(trimmed) }
    }

    mutating func apply(_ event: ActionPlanEvent) {
        guard let open else { return }
        switch event {
        case .planning, .message, .toolFinished, .toolFailed, .toolReused:
            break
        case .toolStarted:
            lines[open].status = .running
        case .toolDenied:
            lines[open].status = .denied
        }
    }

    mutating func finish(_ outcome: Outcome) {
        let status: ActionLine.Status
        switch outcome {
        case .succeeded:
            status = .done
        case .failed(let message):
            status = .failed(reason: ActionLineText.reason(from: message))
        case .cancelled:
            status = .failed(reason: ActionLineText.reason(from: ActionExecutionError.cancelled.localizedDescription))
        }
        for index in lines.indices where lines[index].status == .running {
            lines[index].status = status
        }
        open = nil
    }

    func outcomeText(message: String, succeeded: Bool) -> String? {
        if succeeded, !replies.isEmpty { return replies.joined(separator: " ") }
        let plain = ActionLineText.plain(message)
        if succeeded {
            guard lines.isEmpty else { return nil }
            return plain.isEmpty ? "All done." : plain
        }
        guard !lines.contains(where: { $0.reason != nil }), !plain.isEmpty else { return nil }
        return plain
    }
}
