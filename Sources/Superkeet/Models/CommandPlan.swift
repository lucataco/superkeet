import Foundation

/// One step of a spoken command, classified on its own.
struct CommandClause: Equatable, Sendable {
    let index: Int
    let text: String
    let intent: ActionIntent

    /// Words worth matching against tool names and UI labels for this step.
    var focusTerms: Set<String> { intent.routingTerms }
}

/// A spoken command broken into ordered steps. A single-step command is a
/// plan with one clause and behaves exactly like the undecomposed request.
struct CommandPlan: Equatable, Sendable {
    let command: String
    let clauses: [CommandClause]

    var isCompound: Bool { clauses.count > 1 }
}

enum CommandDecomposer {
    /// Splits at conjunctions and separators (outside quotes) and classifies
    /// each part. Active-tab requests are never split: their scope qualifier
    /// binds the whole sentence to one browser tab.
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

    /// Whether an app opened while the user was speaking already carries out
    /// this clause. Names are compared through the installed-app resolver so
    /// "the Notes app", "Notes", and aliases all match the launched bundle.
    static func clause(_ clause: CommandClause, isSatisfiedBy launch: SpeculativeLaunchResult, resolveApp: (String) -> URL?) -> Bool {
        guard launch.launched != nil else { return false }
        let named: String?
        if let parsed = SpeculativeIntentDetector.leadingClause(in: clause.text) {
            // The same parser that triggered the launch, so filler words and
            // "switch to" phrasing agree with what was heard.
            guard !parsed.hasBoundary, !parsed.containsURL else { return false }
            named = parsed.candidate
        } else if [.openApp, .switchApp].contains(clause.intent.action), !NativeActionStep.hasSequence(clause.text) {
            named = clause.intent.app
        } else {
            return false
        }
        guard let named, let url = resolveApp(named) else { return false }
        return url.standardizedFileURL.path == launch.action.app.url.standardizedFileURL.path
    }
}

/// What earlier steps of the same command have already done. The planner
/// receives this as instructions so each step runs in a fresh, small model
/// session without losing track of the apps that are already open.
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

    /// Nothing an undecomposed, context-free run would not already know.
    var isEmpty: Bool { stepCount <= 1 && completed.isEmpty && openedApps.isEmpty }

    /// The app most recently opened by this command, if any.
    var currentApp: NativeLaunchedApp? { openedApps.last }

    mutating func recordOpened(_ app: NativeLaunchedApp) {
        openedApps.removeAll { $0.processIdentifier == app.processIdentifier }
        openedApps.append(app)
    }

    /// Instructions text appended to the planner's system prompt for this step.
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
