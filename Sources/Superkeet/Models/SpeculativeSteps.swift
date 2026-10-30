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

enum TrailingPolicy: Equatable, Sendable {
    case firstSighting
    case waitForBrowserName
    case confirmed
    case confirmedAtSentenceEnd
    case silentSentenceEnd
    case afterTheSpeakerMoves

    static let minimumSilence: Duration = .milliseconds(300)

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
            return opensOnSight ? .waitForBrowserName : .confirmed
        }
    }

    func decision(_ evidence: TrailingEvidence) -> TrailingDecision {
        switch self {
        case .firstSighting:
            return .commit(.firstSighting)
        case .waitForBrowserName:
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
    var endsSentence: Bool
    var silence: Duration?
    var confirmed = false
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
    case watch
    case drop
}

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
