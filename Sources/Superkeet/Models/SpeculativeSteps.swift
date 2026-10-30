import Foundation

struct SpeculativeStep: Equatable, Sendable {
    let index: Int
    let clause: String
    let action: NativeOpenAction
    let sequence: Int
}

struct SpeculativeStepResult: Equatable, Sendable {
    let step: SpeculativeStep
    let output: String?
    let failure: String?

    var succeeded: Bool { output != nil }

    var launchedApp: NativeLaunchedApp? {
        guard case .openApp = step.action, let output else { return nil }
        return NativeLaunchedApp(summary: output)
    }

    var summary: String {
        let arguments = (try? step.action.argumentsJSON()) ?? "{}"
        return ActionIntentFormatter.summary(toolName: step.action.toolName, argumentsJSON: arguments) ?? step.action.spec.displayName
    }

    var lowercasedSummary: String {
        summary.prefix(1).lowercased() + summary.dropFirst()
    }

    var doneDescription: String {
        guard let output else { return summary }
        var text = ActionLineText.plain(output)
        if text.hasSuffix(".") { text.removeLast() }
        return text
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

struct SpeculativeHandoff: Sendable {
    var launch: SpeculativeLaunch?
    var steps: [SpeculativeStepRun] = []

    var isEmpty: Bool { launch == nil && steps.isEmpty }

    func cancelSteps() {
        steps.forEach { $0.outcome.cancel() }
    }
}

/// When the last clause of a take, still being spoken, may run before the speaker stops.
///
/// The commit decision lives here, as one function of the clause's policy and the evidence the
/// engine has given so far, so the detector holds no per-kind flags.
enum TrailingPolicy: Equatable, Sendable {
    /// An app that resolves exactly or by a unique near match, with no longer installed name it
    /// could still become. The first partial that says so is enough, the rule
    /// `SpeculativeIntentDetector` applies to the leading clause.
    case firstSighting
    /// A site that is not a search. Once its sentence ends it opens on sight. Before that, “in Safari”
    /// could still follow and open the page a second time, so it waits for the speaker to hold still.
    case sentenceEndOrHeldStill
    /// A shortcut, or a site whose ending could still grow (`x.co` on its way to `x.com`).
    case confirmed
    /// A web search, which is open-ended until the sentence is punctuated.
    case confirmedAtSentenceEnd
    /// Typing. Half-heard words are never typed, so it waits for the sentence to end in measured silence.
    case silentSentenceEnd
    /// An app name a longer installed name could still complete. Waits for the speaker to move on.
    case afterTheSpeakerMoves

    /// Silence, measured by the engine, that must follow a punctuated sentence end.
    static let minimumSilence: Duration = .milliseconds(300)

    /// `opensOnSight` is false when the leading launch asks for more than one sighting, so a later
    /// open is held to the same bar.
    static func of(_ action: NativeOpenAction, appNameIsAmbiguous: Bool, opensOnSight: Bool = true) -> TrailingPolicy {
        switch action {
        case .typeText:
            return .silentSentenceEnd
        case .pressShortcut:
            return .confirmed
        case .openApp:
            if appNameIsAmbiguous { return .afterTheSpeakerMoves }
            return opensOnSight ? .firstSighting : .confirmed
        case .openURL(let url, _):
            if SpeculativeStepDetector.isOpenEndedSearch(url) { return .confirmedAtSentenceEnd }
            if SpokenURL.topLevelDomainMayGrow(in: url) { return .confirmed }
            return opensOnSight ? .sentenceEndOrHeldStill : .confirmed
        }
    }

    func decision(_ evidence: TrailingEvidence) -> TrailingDecision {
        switch self {
        case .firstSighting:
            return .commit(.firstSighting)
        case .sentenceEndOrHeldStill:
            if evidence.endsSentence { return .commit(.firstSighting) }
            return evidence.heldStill ? .commit(.heldStill) : .watch
        case .afterTheSpeakerMoves:
            return .drop
        case .silentSentenceEnd:
            return evidence.endedInSilence ? .commit(.silentSentenceEnd) : .watch
        case .confirmedAtSentenceEnd:
            return evidence.endsSentence ? settled(evidence) : .drop
        case .confirmed:
            return settled(evidence)
        }
    }

    private func settled(_ evidence: TrailingEvidence) -> TrailingDecision {
        if evidence.endedInSilence { return .commit(.silentSentenceEnd) }
        if evidence.confirmed { return .commit(.confirmed) }
        if evidence.heldStill { return .commit(.heldStill) }
        return .watch
    }
}

struct TrailingEvidence: Equatable, Sendable {
    /// The latest partial's text ends in `.`, `?` or `!`.
    var endsSentence: Bool
    /// Trailing silence of the engine's latest tick for this take. Nil for an engine that sends none.
    var silence: Duration?
    /// The same action was already read from an earlier partial.
    var confirmed = false
    /// The same action has stood for `trailingHold` with no newer partial.
    var heldStill = false

    var endedInSilence: Bool {
        endsSentence && (silence ?? .zero) >= TrailingPolicy.minimumSilence
    }
}

enum TrailingTrigger: Equatable, Sendable {
    case firstSighting
    case silentSentenceEnd
    case confirmed
    case heldStill
}

enum TrailingDecision: Equatable, Sendable {
    case commit(TrailingTrigger)
    /// Not yet. A newer partial, a tick or the hold timer may still commit it.
    case watch
    /// Not before the speaker moves on.
    case drop
}

/// Reads the running interim text and decides which clauses can already run.
///
/// - A clause is **complete** once the next clause has begun (a separator and a new instruction
///   follow it), so its words are no longer being spoken. Complete native clauses run in order.
/// - The **last** clause is still being spoken, so `TrailingPolicy` decides when it may commit
///   before the speaker stops. An open or a URL commits on its first unambiguous sighting. A
///   shortcut (⌘N, ⌘T, Photo Booth's shutter), a web search once the recogniser has punctuated
///   the end of the sentence, typing, and a URL whose ending could still grow commit when the
///   latest partial ends the sentence and the engine's latest tick reports 300 ms of silence.
///   Shortcuts and searches also commit when *stable*, with the same action on two partials in
///   a row or unchanged for `trailingHold` with no newer partial (the engine only emits a partial
///   when the text changes), which is how an engine without ticks is served. Typing needs the
///   silence, so half-heard words are never typed.
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
        var allows: (NativeOpenAction) -> Bool
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
        let policy: TrailingPolicy
        let sequence: Int
        let firstSeen: Date
    }

    private let environment: Environment
    private let carriedApp: String?
    private let opensOnSight: Bool
    private(set) var steps: [SpeculativeStep] = []
    private var accounted: [Handled] = []
    var handled: Int { accounted.count }
    private(set) var blocked = false
    private(set) var diverged = false
    private var lastSequence = 0
    private var trailing: TrailingCandidate?
    private var endsSentence = false
    private var silence: Duration?
    private var cachedNames: [String]?

    /// `stabilityThreshold` is the leading launch's: a later open runs on its first sighting only
    /// when the launch does too.
    init(environment: Environment, currentApp: String? = nil, stabilityThreshold: Int = 1) {
        self.environment = environment
        self.carriedApp = currentApp
        self.opensOnSight = stabilityThreshold <= 1
    }

    var trailingDeadline: Date? {
        guard !diverged, let trailing, trailing.index == accounted.count else { return nil }
        var evidence = evidence()
        evidence.heldStill = true
        guard trailing.policy.decision(evidence) == .commit(.heldStill) else { return nil }
        return trailing.firstSeen.addingTimeInterval(Self.trailingHold)
    }

    private func evidence() -> TrailingEvidence {
        TrailingEvidence(endsSentence: endsSentence, silence: silence)
    }

    mutating func observe(_ partial: PartialTranscript, launchedApp: SpeculativeApp?, at now: Date = Date()) -> [SpeculativeStep] {
        guard partial.sequence > lastSequence else { return [] }
        lastSequence = partial.sequence
        guard !diverged else { return [] }
        blocked = false

        let (text, movedOn) = CommandClauses.strippingTrailingConjunction(partial.text)
        let clauses = CommandClauses.split(text)
        let completeCount = partial.isFinal || movedOn ? clauses.count : clauses.count - 1
        endsSentence = text.last.map { ".?!".contains($0) } ?? false
        var app = carriedApp ?? launchedApp?.name
        var new: [SpeculativeStep] = []
        var sawTrailing = false

        for (index, clause) in clauses.enumerated() {
            let isTrailing = index >= completeCount
            let context = NativeClauseContext(currentApp: app, resolveApp: environment.resolveApp, isRunning: environment.isRunning)
            let action = NativeClauseRouter.action(for: clause, context: context)

            if index < accounted.count {
                guard matches(accounted[index], action) else {
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
                let policy = trailingPolicy(for: action)
                let pending = trailing.flatMap { $0.index == index && $0.action == action ? $0 : nil }
                var evidence = evidence()
                evidence.confirmed = pending.map { $0.sequence < partial.sequence } ?? false
                switch policy.decision(evidence) {
                case .commit:
                    new.append(commit(index: index, clause: clause, action: action, sequence: partial.sequence))
                    trailing = nil
                case .watch:
                    trailing = pending ?? TrailingCandidate(index: index, clause: clause, action: action, policy: policy, sequence: partial.sequence, firstSeen: now)
                case .drop:
                    trailing = nil
                }
                break
            }

            new.append(commit(index: index, clause: clause, action: action, sequence: partial.sequence))
            app = self.app(after: .step(action), current: app)
        }
        if !sawTrailing { trailing = nil }
        return new
    }

    /// An engine tick says how long the audio has been silent, which a partial can't, because
    /// the engine only sends a partial when the text changes.
    mutating func observe(_ tick: EngineTick) -> [SpeculativeStep] {
        silence = tick.trailingSilence
        guard !diverged, let pending = trailing, pending.index == accounted.count,
              case .commit = pending.policy.decision(evidence()) else { return [] }
        trailing = nil
        return [commit(index: pending.index, clause: pending.clause, action: pending.action, sequence: pending.sequence)]
    }

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

    private mutating func trailingPolicy(for action: NativeOpenAction) -> TrailingPolicy {
        var ambiguous = false
        if case .openApp(let name) = action { ambiguous = isAmbiguousAppName(name) }
        return TrailingPolicy.of(action, appNameIsAmbiguous: ambiguous, opensOnSight: opensOnSight)
    }

    static func isOpenEndedSearch(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.queryItems?.contains { ["q", "query", "search_query", "p", "text"].contains($0.name) } ?? false
    }

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

    static func allows(_ action: NativeOpenAction, policy: ActionApprovalPolicy) -> Bool {
        !policy.requiresApproval(for: action.spec)
    }
}

extension NativeOpenAction {
    var actsInsideApp: Bool {
        switch self {
        case .pressShortcut, .typeText: return true
        case .openApp, .openURL: return false
        }
    }
}
