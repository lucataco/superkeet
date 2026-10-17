import Foundation
import os.log

private let speculativeLog = Logger(subsystem: "com.superkeet.app", category: "SpeculativeLaunch")

struct SpeculativeLaunchResult: Equatable, Sendable {
    let commit: SpeculativeCommit
    let launched: NativeLaunchedApp?
    let failure: String?
    let disagreement: Bool

    var action: SpeculativeAction { commit.action }
    var appName: String { launched?.name ?? commit.action.app.name }
}

struct SpeculativeLaunch: Sendable {
    let commit: SpeculativeCommit
    let disagreement: Bool
    let outcome: Task<Result<NativeLaunchedApp, Error>, Never>

    func result() async -> SpeculativeLaunchResult {
        switch await outcome.value {
        case .success(let launched):
            return SpeculativeLaunchResult(commit: commit, launched: launched, failure: nil, disagreement: disagreement)
        case .failure(let error):
            let message = ActionErrorHandling.isCancellation(error) ? "cancelled" : ActionErrorHandling.userFacingMessage(for: error)
            return SpeculativeLaunchResult(commit: commit, launched: nil, failure: message, disagreement: disagreement)
        }
    }
}

@MainActor
protocol SpeculativeLaunching: AnyObject {
    func wantsInterimTranscripts() -> Bool
    func begin(sessionID: String)
    func end(sessionID: String)
    func take(sessionID: String) -> SpeculativeLaunch?
    func takeHandoff(sessionID: String) -> SpeculativeHandoff?
}

extension SpeculativeLaunching {
    func wantsInterimTranscripts() -> Bool { false }

    func takeHandoff(sessionID: String) -> SpeculativeHandoff? {
        take(sessionID: sessionID).map { SpeculativeHandoff(launch: $0) }
    }
}

@MainActor
final class SpeculativeLaunchCoordinator: ObservableObject, SpeculativeLaunching {
    static let shared = SpeculativeLaunchCoordinator()

    struct Listening: Equatable {
        let sessionID: String
        var transcript: String
    }

    enum Activity: Equatable {
        case launching(String)
        case launched(NativeLaunchedApp)
        case failed(String, String)

        var appName: String {
            switch self {
            case .launching(let name), .failed(let name, _): return name
            case .launched(let launched): return launched.name
            }
        }
    }

    enum StepActivity: Equatable {
        case running(SpeculativeStep)
        case done(SpeculativeStepResult)
        case failed(SpeculativeStepResult)

        var step: SpeculativeStep {
            switch self {
            case .running(let step): return step
            case .done(let result), .failed(let result): return result.step
            }
        }
    }

    @Published private(set) var activity: Activity?
    @Published private(set) var stepActivity: StepActivity?
    @Published private(set) var stepActivities: [StepActivity] = []
    @Published private(set) var listening: Listening?

    private final class Session {
        struct RunningStep {
            let step: SpeculativeStep
            let task: Task<Result<String, Error>, Never>
        }

        let id: String
        var detector: SpeculativeIntentDetector
        var stepDetector: SpeculativeStepDetector
        var policy: ActionApprovalPolicy
        var listener: Task<Void, Never>?
        var trailingTimer: Task<Void, Never>?
        var launch: Task<Result<NativeLaunchedApp, Error>, Never>?
        var steps: [RunningStep] = []
        var waitingForRun = false
        var held = false

        init(id: String, detector: SpeculativeIntentDetector, stepDetector: SpeculativeStepDetector, policy: ActionApprovalPolicy) {
            self.id = id
            self.detector = detector
            self.stepDetector = stepDetector
            self.policy = policy
        }
    }

    private let settings: AppSettings
    private let source: (any PartialTranscriptSource)?
    private let inventory: InstalledAppInventory
    private let launcher: any NativeAppLaunching
    private let executor: any NativeActionExecuting
    private let awaitWindow: @MainActor (Int32) async -> Bool
    private let carriedApp: @MainActor () -> String?
    private let runIsActive: @MainActor () -> Bool
    private let audit: ActionAuditStore
    private let stabilityThreshold: Int
    private let now: @MainActor () -> Date
    private var session: Session?
    private var prepared = false

    init(
        settings: AppSettings = .shared,
        source: (any PartialTranscriptSource)? = PartialTranscriptSources.make(),
        inventory: InstalledAppInventory = .shared,
        launcher: any NativeAppLaunching = NativeActionExecutor.shared,
        executor: (any NativeActionExecuting)? = nil,
        awaitWindow: (@MainActor (Int32) async -> Bool)? = nil,
        carriedApp: (@MainActor () -> String?)? = nil,
        runIsActive: (@MainActor () -> Bool)? = nil,
        audit: ActionAuditStore = .shared,
        stabilityThreshold: Int = 1,
        now: (@MainActor () -> Date)? = nil
    ) {
        self.now = now ?? { Date() }
        self.settings = settings
        self.source = source
        self.inventory = inventory
        self.launcher = launcher
        self.executor = executor ?? NativeActionExecutor.shared
        self.awaitWindow = awaitWindow ?? { await NativeActionExecutor.shared.waitForWindow(processIdentifier: $0) }
        self.carriedApp = carriedApp ?? { AgentSessionController.shared.carriedApp?.name }
        self.runIsActive = runIsActive ?? { AgentSessionController.shared.isRunning }
        self.audit = audit
        self.stabilityThreshold = stabilityThreshold
    }

    var isSupported: Bool { source != nil }

    var isEnabled: Bool { settings.actionsEnabled && settings.instantAppLaunchEnabled && source != nil }

    var streamsInterim: Bool { settings.actionsEnabled && source != nil }

    var activeSessionID: String? { session?.id }

    func wantsInterimTranscripts() -> Bool { streamsInterim }

    func availability() async -> PartialTranscriptAvailability {
        guard let source else { return .requiresNewerOS }
        return await source.availability()
    }

    func recognizerName() async -> String? {
        guard let source else { return nil }
        if let preferred = source as? PreferredPartialSource {
            return await preferred.preferredSource()?.displayName
        }
        return await source.availability().isAvailable ? source.displayName : nil
    }

    func installAssets() async throws {
        guard let source else { throw SpeechAnalyzerEngineError.notAvailable(.requiresNewerOS) }
        try await source.installAssets()
        await prepare()
    }

    func prepare() async {
        guard streamsInterim, let source else { return }
        if isEnabled { inventory.refresh() }
        let availability = await source.availability()
        guard availability.isAvailable else {
            speculativeLog.info("Live command recognition unavailable: \(String(describing: availability), privacy: .public)")
            return
        }
        if !prepared {
            prepared = true
            await source.prewarm()
        }
    }

    func begin(sessionID: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard streamsInterim, let source else { return }
        discardSession()
        if isEnabled { inventory.refresh() }
        let session = makeSession(id: sessionID)
        self.session = session
        listening = Listening(sessionID: sessionID, transcript: "")
        audit.beginTimeline(replacing: true)
        session.listener = Task { @MainActor [weak self] in
            guard self?.session === session, !Task.isCancelled else { return }
            do {
                let partials = try await source.start(sessionID: sessionID)
                guard let self, self.session === session else {
                    if self?.session == nil { source.stop() }
                    return
                }
                for await partial in partials {
                    guard self.session === session else { break }
                    self.listening?.transcript = partial.text
                    guard self.isEnabled, self.mayRunEarly(session) else { continue }
                    if let commit = session.detector.observe(partial),
                       SpeculativeStepDetector.allows(.openApp(name: commit.action.app.name), policy: session.policy) {
                        self.launch(commit, in: session)
                    }
                    let launchedApp = session.launch == nil ? nil : session.detector.commit?.action.app
                    for step in session.stepDetector.observe(partial, launchedApp: launchedApp, at: self.now()) {
                        self.run(step, in: session)
                    }
                    self.scheduleTrailingCommit(in: session)
                }
            } catch is CancellationError {
                if self?.session === session { self?.discardSession() }
            } catch {
                speculativeLog.error("Live recognition did not start: \(error.localizedDescription, privacy: .public)")
                if self?.session === session { self?.discardSession() }
            }
        }
    }

    func end(sessionID: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard session?.id == sessionID else { return }
        discardSession()
    }

    func take(sessionID: String) -> SpeculativeLaunch? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let session, session.id == sessionID else { return nil }
        self.session = nil
        source?.stop()
        session.listener?.cancel()
        session.trailingTimer?.cancel()
        activity = nil
        stepActivity = nil
        stepActivities = []
        listening = nil
        guard let commit = session.detector.commit, let launch = session.launch else { return nil }
        return SpeculativeLaunch(commit: commit, disagreement: session.detector.disagreement, outcome: launch)
    }

    func takeHandoff(sessionID: String) -> SpeculativeHandoff? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let session, session.id == sessionID else { return nil }
        let steps = session.steps.map { SpeculativeStepRun(step: $0.step, outcome: $0.task) }
        let launch = take(sessionID: sessionID)
        guard launch != nil || !steps.isEmpty else { return nil }
        return SpeculativeHandoff(launch: launch, steps: steps)
    }

    private func makeSession(id: String) -> Session {
        let environment = inventory.detectorEnvironment
        let policy = settings.actionApprovalPolicy
        let stepDetector = SpeculativeStepDetector(environment: .init(
            resolveApp: environment.resolveApp, isRunning: environment.isRunning,
            allows: { SpeculativeStepDetector.allows($0, policy: policy) },
            installedNames: environment.installedNames
        ), currentApp: carriedApp())
        let detector = SpeculativeIntentDetector(environment: environment, stabilityThreshold: stabilityThreshold)
        return Session(id: id, detector: detector, stepDetector: stepDetector, policy: policy)
    }

    /// Early steps must not type or switch apps under a run that is still going. While one is,
    /// nothing runs early; once it ends, detection starts over from the app that run left behind.
    /// A run that starts after early work began stops it, and the final command does the rest.
    private func mayRunEarly(_ session: Session) -> Bool {
        guard !session.held else { return false }
        guard runIsActive() else {
            if session.waitingForRun {
                session.waitingForRun = false
                let fresh = makeSession(id: session.id)
                session.detector = fresh.detector
                session.stepDetector = fresh.stepDetector
                session.policy = fresh.policy
            }
            return true
        }
        if session.launch == nil, session.steps.isEmpty {
            session.waitingForRun = true
        } else {
            session.held = true
            session.steps.forEach { $0.task.cancel() }
        }
        return false
    }

    private func setStepActivity(_ activity: StepActivity) {
        stepActivity = activity
        if let index = stepActivities.firstIndex(where: { $0.step == activity.step }) {
            stepActivities[index] = activity
        } else {
            stepActivities.append(activity)
        }
    }

    /// The engine only sends a partial when the text changes, so a last clause that stays the
    /// same needs a timer to notice it has held still.
    private func scheduleTrailingCommit(in session: Session) {
        session.trailingTimer?.cancel()
        session.trailingTimer = nil
        guard let deadline = session.stepDetector.trailingDeadline else { return }
        let delay = max(0, deadline.timeIntervalSince(now()))
        session.trailingTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(delay * 1_000) + 5))
            guard !Task.isCancelled, let self, self.session === session, self.isEnabled, self.mayRunEarly(session) else { return }
            for step in session.stepDetector.commitStableTrailing(at: self.now()) {
                speculativeLog.info("Last clause held still; running it before the speaker stops")
                self.run(step, in: session)
            }
        }
    }

    private func run(_ step: SpeculativeStep, in session: Session) {
        let previous = session.steps.last?.task
        let launch = session.launch
        let executor = self.executor
        let awaitWindow = self.awaitWindow
        setStepActivity(.running(step))
        speculativeLog.info("Speculative \(step.action.toolName, privacy: .public) for clause #\(step.index + 1) (partial #\(step.sequence))")
        let task = Task { @MainActor [weak self] in
            var launched: NativeLaunchedApp?
            if let launch, case .success(let app) = await launch.value { launched = app }
            if let previous { _ = await previous.value }
            if step.action.actsInsideApp, let launched, !launched.windowReady {
                _ = await awaitWindow(launched.processIdentifier)
            }
            let outcome: Result<String, Error>
            do {
                outcome = .success(try await executor.execute(step.action))
            } catch {
                outcome = .failure(error)
            }
            self?.finishStep(step, outcome: outcome, session: session)
            return outcome
        }
        session.steps.append(Session.RunningStep(step: step, task: task))
    }

    private func finishStep(_ step: SpeculativeStep, outcome: Result<String, Error>, session: Session) {
        switch outcome {
        case .success(let output):
            let result = SpeculativeStepResult(step: step, output: output, failure: nil)
            recordStep(step, outcome: "speculative", detail: output)
            if self.session === session { setStepActivity(.done(result)) }
        case .failure(let error):
            let cancelled = ActionErrorHandling.isCancellation(error)
            let message = ActionErrorHandling.userFacingMessage(for: error)
            let result = SpeculativeStepResult(step: step, output: nil, failure: cancelled ? "cancelled" : message)
            recordStep(step, outcome: cancelled ? "cancelled" : "failed", detail: cancelled ? nil : message)
            if self.session === session {
                if cancelled {
                    stepActivity = nil
                    stepActivities.removeAll { $0.step == step }
                } else {
                    setStepActivity(.failed(result))
                }
            }
        }
    }

    private func recordStep(_ step: SpeculativeStep, outcome: String, detail: String?) {
        guard settings.actionAuditEnabled else { return }
        audit.record(
            serverName: "superkeet",
            toolName: step.action.toolName,
            risk: step.action.spec.risk,
            argumentsJSON: (try? step.action.argumentsJSON()) ?? "{}",
            outcome: outcome,
            detail: ["Ran while speaking (clause #\(step.index + 1), partial #\(step.sequence)).", detail].compactMap { $0 }.joined(separator: " ")
        )
    }

    private func launch(_ commit: SpeculativeCommit, in session: Session) {
        let app = commit.action.app
        activity = .launching(app.name)
        speculativeLog.info("Speculative \(String(describing: commit.reason), privacy: .public) launch of \(app.name, privacy: .public)")
        let launcher = self.launcher
        session.launch = Task { @MainActor [weak self] in
            let outcome: Result<NativeLaunchedApp, Error>
            do {
                outcome = .success(try await launcher.launch(applicationAt: app.url, awaitWindow: false))
            } catch {
                outcome = .failure(error)
            }
            self?.finishLaunch(commit, outcome: outcome, session: session)
            return outcome
        }
    }

    private func finishLaunch(_ commit: SpeculativeCommit, outcome: Result<NativeLaunchedApp, Error>, session: Session) {
        let app = commit.action.app
        switch outcome {
        case .success(let launched):
            record(commit, outcome: "speculative", detail: launched.summary)
            if self.session === session { activity = .launched(launched) }
        case .failure(let error):
            let cancelled = ActionErrorHandling.isCancellation(error)
            let message = ActionErrorHandling.userFacingMessage(for: error)
            record(commit, outcome: cancelled ? "cancelled" : "failed", detail: cancelled ? nil : message)
            if self.session === session { activity = cancelled ? nil : .failed(app.name, message) }
        }
    }

    private func record(_ commit: SpeculativeCommit, outcome: String, detail: String?) {
        guard settings.actionAuditEnabled else { return }
        let arguments = (try? NativeOpenAction.openApp(name: commit.action.app.name).argumentsJSON()) ?? "{}"
        let reason: String
        switch commit.reason {
        case .clauseBoundary: reason = "clause boundary"
        case .stable(let count): reason = "stable across \(count) partials"
        case .finalized: reason = "finalized text"
        }
        let verb = commit.action.isActivation ? "activated" : "launched"
        audit.record(
            serverName: "superkeet",
            toolName: "open_app",
            risk: .mutating,
            argumentsJSON: arguments,
            outcome: outcome,
            detail: ["Speculatively \(verb) while speaking (\(reason), partial #\(commit.sequence)).", detail]
                .compactMap { $0 }.joined(separator: " ")
        )
    }

    private func discardSession() {
        guard let session else { return }
        self.session = nil
        source?.stop()
        session.listener?.cancel()
        session.trailingTimer?.cancel()
        session.steps.forEach { $0.task.cancel() }
        activity = nil
        stepActivity = nil
        stepActivities = []
        listening = nil
    }
}

extension SpeculativeAction {
    var isActivation: Bool {
        if case .activate = self { return true }
        return false
    }
}
