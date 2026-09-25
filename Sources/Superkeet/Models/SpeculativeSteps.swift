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

/// Reads the running interim text and decides which clauses can already run.
///
/// - A clause is **complete** once the next clause has begun (a separator and a new instruction
///   follow it), so its words are no longer being spoken. Complete native clauses run in order.
/// - The **last** clause is still being spoken, so it runs early only when it is safe to commit
///   before the speaker stops: an open, a URL that isn't an open-ended search, or an app shortcut
///   (⌘N, ⌘T, Photo Booth's shutter), or a web search once the recogniser has punctuated the
///   end of the sentence. It must also be *stable*: the same action on two partials in
///   a row, or unchanged for `trailingHold` with no newer partial (the engine only emits a partial
///   when the text changes). Typing never commits early, so half-heard words are never typed.
/// - A clause only the planner can do stops early execution at that point: every later step would
///   change the frontmost app or its contents under it. The stop is re-evaluated on every partial,
///   so a recogniser correction ("umce" becoming a real request) lets execution continue.
/// - Handled clauses are re-checked against each new partial. If an earlier clause now means
///   something else, the positions can no longer be trusted and early execution stops for the
///   rest of the utterance; the final command sorts out what still needs doing.
struct SpeculativeStepDetector {
    struct Environment {
        var resolveApp: (String) -> URL?
        var isRunning: (URL) -> Bool
        /// The approval policy's say on running this action without a card.
        var allows: (NativeOpenAction) -> Bool
        /// Names of installed apps, used so a trailing "open Photo" doesn't launch before the
        /// speaker gets to "Booth".
        var installedNames: () -> [String] = { [] }
    }

    /// How long the last clause's action must stay the same, with no newer partial, before it
    /// runs. Longer than the engine's partial cadence, so a word still being spoken would have
    /// produced a new partial first.
    static let trailingHold: TimeInterval = 0.7

    private enum Handled: Equatable {
        case launch(path: String)
        case step(NativeOpenAction)
    }

    private struct TrailingCandidate {
        let index: Int
        let clause: String
        let action: NativeOpenAction
        let sequence: Int
        let firstSeen: Date
    }

    private let environment: Environment
    private let carriedApp: String?
    private(set) var steps: [SpeculativeStep] = []
    private var accounted: [Handled] = []
    /// Clauses accounted for: the early app launch plus every step run so far.
    var handled: Int { accounted.count }
    /// Whether the latest partial stopped at a clause that can't run early.
    private(set) var blocked = false
    /// Whether the transcript rewrote a clause that already ran; early execution is over.
    private(set) var diverged = false
    private var lastSequence = 0
    private var trailing: TrailingCandidate?
    private var cachedNames: [String]?

    /// `currentApp` is the app the previous utterance of a listening session acted in, so "type
    /// hello" spoken on its own still has a target.
    init(environment: Environment, currentApp: String? = nil) {
        self.environment = environment
        self.carriedApp = currentApp
    }

    /// When the pending last clause will be stable enough to run, if one is waiting.
    var trailingDeadline: Date? {
        guard !diverged, let trailing, trailing.index == accounted.count else { return nil }
        return trailing.firstSeen.addingTimeInterval(Self.trailingHold)
    }

    /// Newly runnable native clauses, in order. `launchedApp` is the app the launch detector
    /// already opened for the first clause, which is therefore skipped rather than opened twice.
    mutating func observe(_ partial: PartialTranscript, launchedApp: SpeculativeApp?, at now: Date = Date()) -> [SpeculativeStep] {
        guard partial.sequence > lastSequence else { return [] }
        lastSequence = partial.sequence
        guard !diverged else { return [] }
        blocked = false

        // "… and" with nothing after it yet: the speaker has moved on, so every clause so far is
        // complete. Otherwise the last clause is still being spoken.
        let (text, movedOn) = CommandClauses.strippingTrailingConjunction(partial.text)
        let clauses = CommandClauses.split(text)
        let completeCount = partial.isFinal || movedOn ? clauses.count : clauses.count - 1
        // The recogniser punctuates when it hears the sentence end ("… Norbert Wiener?").
        let endsSentence = text.last.map { ".?!".contains($0) } ?? false
        var app = carriedApp ?? launchedApp?.name
        var new: [SpeculativeStep] = []
        var sawTrailing = false

        for (index, clause) in clauses.enumerated() {
            let isTrailing = index >= completeCount
            let context = NativeClauseContext(currentApp: app, resolveApp: environment.resolveApp, isRunning: environment.isRunning)
            let action = NativeClauseRouter.action(for: clause, context: context)

            if index < accounted.count {
                guard matches(accounted[index], action) else {
                    // The words still being spoken may read differently for a moment; only a
                    // finished clause that changed meaning is a real divergence.
                    if !isTrailing { diverged = true; trailing = nil; return new }
                    break
                }
                app = self.app(after: accounted[index], current: app)
                continue
            }

            guard let action else { blocked = true; break }
            if index == 0, let launchedApp, case .openApp(let name) = action,
               environment.resolveApp(name)?.standardizedFileURL.path == launchedApp.url.standardizedFileURL.path {
                accounted.append(.launch(path: launchedApp.url.standardizedFileURL.path))
                app = launchedApp.name
                continue
            }
            guard environment.allows(action) else { blocked = true; break }

            if isTrailing {
                sawTrailing = true
                guard canCommitWhileSpoken(action, endsSentence: endsSentence) else { trailing = nil; break }
                if let pending = trailing, pending.index == index, pending.action == action, pending.sequence < partial.sequence {
                    // Confirmed by a second partial.
                    new.append(commit(index: index, clause: clause, action: action, sequence: partial.sequence))
                    trailing = nil
                } else if trailing?.index != index || trailing?.action != action {
                    trailing = TrailingCandidate(index: index, clause: clause, action: action, sequence: partial.sequence, firstSeen: now)
                }
                break
            }

            new.append(commit(index: index, clause: clause, action: action, sequence: partial.sequence))
            app = self.app(after: .step(action), current: app)
        }
        if !sawTrailing { trailing = nil }
        return new
    }

    /// Runs the pending last clause once it has held still for `trailingHold`. Call when
    /// `trailingDeadline` passes without a newer partial.
    mutating func commitStableTrailing(at now: Date = Date()) -> [SpeculativeStep] {
        guard let deadline = trailingDeadline, now >= deadline, let pending = trailing else { return [] }
        trailing = nil
        return [commit(index: pending.index, clause: pending.clause, action: pending.action, sequence: pending.sequence)]
    }

    private mutating func commit(index: Int, clause: String, action: NativeOpenAction, sequence: Int) -> SpeculativeStep {
        let step = SpeculativeStep(index: index, clause: clause, action: action, sequence: sequence)
        steps.append(step)
        accounted.append(.step(action))
        return step
    }

    private func matches(_ handled: Handled, _ action: NativeOpenAction?) -> Bool {
        switch handled {
        case .step(let ran):
            return ran == action
        case .launch(let path):
            guard case .openApp(let name)? = action else { return false }
            return environment.resolveApp(name)?.standardizedFileURL.path == path
        }
    }

    private func app(after handled: Handled, current: String?) -> String? {
        switch handled {
        case .launch(let path):
            return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        case .step(.openApp(let name)):
            return environment.resolveApp(name)?.deletingPathExtension().lastPathComponent ?? current
        case .step:
            return current
        }
    }

    /// What the last clause may do before the speaker has finished it.
    private mutating func canCommitWhileSpoken(_ action: NativeOpenAction, endsSentence: Bool) -> Bool {
        switch action {
        case .typeText:
            return false
        case .openURL(let url, _):
            // A search's query grows while the speaker talks, so it waits for the sentence to
            // end. A wrong early search is harmless: the final command reruns the full query.
            return !Self.isOpenEndedSearch(url) || endsSentence
        case .pressShortcut:
            return true
        case .openApp(let name):
            return !isAmbiguousAppName(name)
        }
    }

    /// A web search's query grows as the speaker talks ("Norbert" → "Norbert Wiener").
    static func isOpenEndedSearch(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.queryItems?.contains { ["q", "query", "search_query", "p", "text"].contains($0.name) } ?? false
    }

    /// Another installed app whose name extends the spoken one ("Photo" while "Photo Booth" is
    /// installed) means the speaker may be mid-name.
    private mutating func isAmbiguousAppName(_ spoken: String) -> Bool {
        guard let url = environment.resolveApp(spoken) else { return true }
        let names = cachedNames ?? environment.installedNames().map(AppResolver.normalizedName)
        cachedNames = names
        let spokenKey = AppResolver.matchKey(AppResolver.normalizedName(spoken))
        let ownKey = AppResolver.matchKey(AppResolver.normalizedName(url.deletingPathExtension().lastPathComponent))
        guard !spokenKey.isEmpty else { return true }
        return names.contains {
            let key = AppResolver.matchKey($0)
            return key != spokenKey && key != ownKey && key.hasPrefix(spokenKey)
        }
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
