import Foundation

/// A clause of the utterance that was carried out natively while the user was still speaking.
struct SpeculativeStep: Equatable, Sendable {
    /// Position among the utterance's clauses, as split from the interim text.
    let index: Int
    let clause: String
    let action: NativeOpenAction
    /// The interim partial whose text completed the clause.
    let sequence: Int
}

struct SpeculativeStepResult: Equatable, Sendable {
    let step: SpeculativeStep
    let output: String?
    let failure: String?

    var succeeded: Bool { output != nil }

    /// The app an early `open_app` step reported, so later steps act in it.
    var launchedApp: NativeLaunchedApp? {
        guard case .openApp = step.action, let output else { return nil }
        return NativeLaunchedApp(summary: output)
    }

    /// "Press ⌘N in Notes", "Type “hello” in Notes", "Search the web for “cats” in Helium".
    var summary: String {
        let arguments = (try? step.action.argumentsJSON()) ?? "{}"
        return ActionIntentFormatter.summary(toolName: step.action.toolName, argumentsJSON: arguments) ?? step.action.spec.displayName
    }

    /// The summary as it reads mid-sentence: "press ⌘N in Notes".
    var lowercasedSummary: String {
        summary.prefix(1).lowercased() + summary.dropFirst()
    }

    /// The executor's report without its bookkeeping: "Pressed ⌘N in Notes".
    var doneDescription: String {
        guard let output else { return summary }
        var text = output.replacingOccurrences(of: #"\s*\(pid \d+(?:, [^)]*)?\)"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\.\s*(?:Its window is on screen\.|No window has appeared yet\.)\z"#, with: "", options: .regularExpression)
        if text.hasSuffix(".") { text.removeLast() }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct SpeculativeStepRun: Sendable {
    let step: SpeculativeStep
    let outcome: Task<Result<String, Error>, Never>

    func result() async -> SpeculativeStepResult {
        switch await outcome.value {
        case .success(let output):
            return SpeculativeStepResult(step: step, output: output, failure: nil)
        case .failure(let error):
            let message = ActionErrorHandling.isCancellation(error) ? "cancelled" : ActionErrorHandling.userFacingMessage(for: error)
            return SpeculativeStepResult(step: step, output: nil, failure: message)
        }
    }
}

/// Everything that ran while the user was speaking, handed to the command once the final
/// transcript lands so those clauses are recognised as done instead of repeated.
struct SpeculativeHandoff: Sendable {
    var launch: SpeculativeLaunch?
    var steps: [SpeculativeStepRun] = []

    var isEmpty: Bool { launch == nil && steps.isEmpty }
}

/// Reads the running interim text and decides which clauses can already run. A clause is
/// complete once the next clause has begun (a separator and a new instruction follow it), so its
/// words are no longer being spoken. Clauses run in order; the first one that needs the planner
/// stops early execution for the rest of the utterance, since later steps may depend on it.
struct SpeculativeStepDetector {
    struct Environment {
        var resolveApp: (String) -> URL?
        var isRunning: (URL) -> Bool
        /// The approval policy's say on running this action without a card.
        var allows: (NativeOpenAction) -> Bool
    }

    private let environment: Environment
    private(set) var steps: [SpeculativeStep] = []
    /// Clauses accounted for: the early app launch plus every step run so far.
    private(set) var handled = 0
    private(set) var blocked = false
    private var lastSequence = 0
    private var currentApp: String?

    /// `currentApp` is the app the previous utterance of a listening session acted in, so "type
    /// hello" spoken on its own still has a target.
    init(environment: Environment, currentApp: String? = nil) {
        self.environment = environment
        self.currentApp = currentApp
    }

    /// Newly complete native clauses, in order. `launchedApp` is the app the launch detector
    /// already opened for the first clause, which is therefore skipped rather than opened twice.
    mutating func observe(_ partial: PartialTranscript, launchedApp: SpeculativeApp?) -> [SpeculativeStep] {
        guard partial.sequence > lastSequence else { return [] }
        lastSequence = partial.sequence
        guard !blocked else { return [] }
        if currentApp == nil, let launchedApp { currentApp = launchedApp.name }

        // "… and" with nothing after it yet: the speaker has moved on, so every clause so far is
        // complete. Otherwise the last clause is still being spoken.
        let (text, movedOn) = CommandClauses.strippingTrailingConjunction(partial.text)
        let clauses = CommandClauses.split(text)
        let complete = partial.isFinal || movedOn ? clauses : Array(clauses.dropLast())
        var new: [SpeculativeStep] = []
        while handled < complete.count {
            let clause = complete[handled]
            let context = NativeClauseContext(currentApp: currentApp, resolveApp: environment.resolveApp, isRunning: environment.isRunning)
            guard let action = NativeClauseRouter.action(for: clause, context: context) else {
                blocked = true
                break
            }
            if handled == 0, let launchedApp, case .openApp(let name) = action,
               environment.resolveApp(name)?.standardizedFileURL.path == launchedApp.url.standardizedFileURL.path {
                handled += 1
                continue
            }
            guard environment.allows(action) else {
                blocked = true
                break
            }
            let step = SpeculativeStep(index: handled, clause: clause, action: action, sequence: partial.sequence)
            steps.append(step)
            new.append(step)
            handled += 1
            if case .openApp(let name) = action, let url = environment.resolveApp(name) {
                currentApp = url.deletingPathExtension().lastPathComponent
            }
        }
        return new
    }

    /// Opens and URL loads run early under every policy that allows the instant launch; steps
    /// inside an app run early only when the policy would not have asked about them anyway.
    static func allows(_ action: NativeOpenAction, policy: ActionApprovalPolicy) -> Bool {
        switch action {
        case .openApp, .openURL: return true
        case .pressShortcut, .typeText: return !policy.requiresApproval(for: action.spec)
        }
    }
}

extension NativeOpenAction {
    /// Shortcuts and typing land inside an app's window; opens do not need one.
    var actsInsideApp: Bool {
        switch self {
        case .pressShortcut, .typeText: return true
        case .openApp, .openURL: return false
        }
    }
}
