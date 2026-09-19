import Foundation

struct CommandClause: Equatable, Sendable {
    let index: Int
    let text: String
    let intent: ActionIntent

    var focusTerms: Set<String> { intent.routingTerms }
}

struct CommandPlan: Equatable, Sendable {
    let command: String
    let clauses: [CommandClause]

    var isCompound: Bool { clauses.count > 1 }
}

enum CommandDecomposer {
    static func decompose(_ command: String) -> CommandPlan {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let whole = HeuristicIntentExtractor.intent(for: trimmed)
        let parts = whole.scope == .activeTab ? [trimmed] : CommandClauses.split(trimmed)
        let texts = parts.isEmpty ? [trimmed] : parts
        let clauses = texts.enumerated().map { index, text in
            CommandClause(index: index, text: text, intent: texts.count == 1 ? whole : HeuristicIntentExtractor.intent(for: text))
        }
        return CommandPlan(command: trimmed, clauses: clauses)
    }

    static func clause(_ clause: CommandClause, isSatisfiedBy launch: SpeculativeLaunchResult, resolveApp: (String) -> URL?) -> Bool {
        guard launch.launched != nil else { return false }
        let named: String?
        if let parsed = SpeculativeIntentDetector.leadingClause(in: clause.text) {
            guard !parsed.hasBoundary, !parsed.containsURL else { return false }
            named = parsed.candidate
        } else if [.openApp, .switchApp].contains(clause.intent.action), !CommandClauses.hasSequence(clause.text) {
            named = clause.intent.app
        } else {
            return false
        }
        guard let named, let url = resolveApp(named) else { return false }
        return url.standardizedFileURL.path == launch.action.app.url.standardizedFileURL.path
    }
}

struct ActionPlanContext: Equatable, Sendable {
    struct CompletedStep: Equatable, Sendable {
        let clause: String
        let summary: String
    }

    let command: String
    var stepNumber = 1
    var stepCount = 1
    var completed: [CompletedStep] = []
    var openedApps: [NativeLaunchedApp] = []

    init(command: String) {
        self.command = command
    }

    var isFinalStep: Bool { stepNumber >= stepCount }

    var isEmpty: Bool { stepCount <= 1 && completed.isEmpty && openedApps.isEmpty }

    var currentApp: NativeLaunchedApp? { openedApps.last }

    mutating func recordOpened(_ app: NativeLaunchedApp) {
        openedApps.removeAll { $0.processIdentifier == app.processIdentifier }
        openedApps.append(app)
    }

    func instructions(for clause: String) -> String {
        var lines: [String] = []
        if stepCount > 1 {
            lines.append("The user's full command was: \"\(command)\". It has \(stepCount) steps; you are carrying out step \(stepNumber) only: \"\(clause)\".")
        }
        if !completed.isEmpty {
            lines.append("Already done:")
            for (offset, step) in completed.enumerated() {
                lines.append("\(offset + 1). \"\(step.clause)\" — \(ActionResultText.truncate(step.summary, limit: 160))")
            }
        }
        for app in openedApps {
            let window = app.windowReady ? "its window is on screen" : "its window may still be appearing"
            lines.append("\(app.name) is already open (pid \(app.processIdentifier); \(window)). Do not open it again; act inside it.")
        }
        if let app = currentApp {
            lines.append("Unless this step names another app, it refers to \(app.name).")
        }
        if stepCount > 1 && !isFinalStep {
            lines.append("Later steps follow; do not carry them out now.")
        }
        return lines.joined(separator: "\n")
    }
}
