import Foundation

/// One row of the HUD checklist: a step of the command, a tool call, an app
/// opened while the user was speaking, or a note. Unlike the append-only
/// activity log, a row keeps its identity and its status changes in place, so
/// the HUD can show `Running…` turn into `✓` rather than two lines.
struct ActionChecklistItem: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case speculative
        case step(number: Int, total: Int)
        case tool
        case note
    }

    enum Status: Equatable, Sendable {
        case pending
        case running
        case done
        case reused
        case skipped
        case failed
        case denied
        case info
    }

    let id: UUID
    let kind: Kind
    var status: Status
    var title: String
    var detail: String?

    init(id: UUID = UUID(), kind: Kind, status: Status, title: String, detail: String? = nil) {
        self.id = id
        self.kind = kind
        self.status = status
        self.title = title
        self.detail = detail
    }
}

/// The HUD's view of a running command. Pure value type; the session
/// controller feeds it the same events that drive the activity log.
struct ActionChecklist: Equatable, Sendable {
    private(set) var items: [ActionChecklistItem] = []
    /// The tool row that is currently running, if any.
    private var runningToolID: UUID?

    var isEmpty: Bool { items.isEmpty }

    /// Rows shown on the HUD when space is short: the newest `limit` rows,
    /// always keeping the current step header so the list stays oriented.
    func visibleItems(limit: Int) -> (hidden: Int, items: [ActionChecklistItem]) {
        guard items.count > limit, limit > 0 else { return (0, items) }
        var tail = Array(items.suffix(limit))
        if let step = items.last(where: { if case .step = $0.kind { return true }; return false }), !tail.contains(step) {
            tail[0] = step
        }
        return (items.count - tail.count, tail)
    }

    mutating func addSpeculative(_ result: SpeculativeLaunchResult) {
        let name = result.appName
        if result.launched != nil {
            let verb = result.action.isActivation ? "Switched to" : "Opened"
            items.append(.init(kind: .speculative, status: .done, title: "\(verb) \(name) while you were speaking"))
        } else if let failure = result.failure, failure != "cancelled" {
            items.append(.init(kind: .speculative, status: .failed, title: "Couldn't open \(name) early", detail: failure))
        }
        if result.disagreement {
            items.append(.init(kind: .note, status: .info, title: "Later speech named a different app; the final command decides"))
        }
    }

    mutating func addStep(number: Int, total: Int, text: String) {
        items.append(.init(kind: .step(number: number, total: total), status: .running, title: text))
    }

    /// Marks the current step's outcome; `nil` output means an earlier launch covered it.
    mutating func completeStep(skippedBecause reason: String? = nil) {
        guard let index = items.lastIndex(where: { if case .step = $0.kind { return true }; return false }) else { return }
        if let reason {
            items[index].status = .skipped
            items[index].detail = reason
        } else if items[index].status == .running {
            items[index].status = .done
        }
    }

    mutating func addNote(_ text: String) {
        items.append(.init(kind: .note, status: .info, title: text))
    }

    mutating func apply(_ event: ActionPlanEvent) {
        switch event {
        case .planning, .message:
            break
        case .toolStarted(let spec):
            let item = ActionChecklistItem(kind: .tool, status: .running, title: spec.displayName)
            items.append(item)
            runningToolID = item.id
        case .toolFinished(let spec, _):
            settleRunningTool(spec, status: .done)
        case .toolFailed(let spec, let message):
            settleRunningTool(spec, status: .failed, detail: message)
        case .toolDenied(let spec):
            settleRunningTool(spec, status: .denied, detail: "Not approved")
        case .toolReused(let spec):
            items.append(.init(kind: .tool, status: .reused, title: spec.displayName, detail: "Already done; result reused"))
        }
    }

    /// When the command ends, anything still marked running did not complete.
    mutating func finish(succeeded: Bool) {
        for index in items.indices where items[index].status == .running {
            items[index].status = succeeded ? .done : .failed
        }
        runningToolID = nil
    }

    private mutating func settleRunningTool(_ spec: ActionToolSpec, status: ActionChecklistItem.Status, detail: String? = nil) {
        if let id = runningToolID, let index = items.firstIndex(where: { $0.id == id }), items[index].title == spec.displayName {
            items[index].status = status
            items[index].detail = detail
        } else {
            items.append(.init(kind: .tool, status: status, title: spec.displayName, detail: detail))
        }
        runningToolID = nil
    }
}
