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
}

extension SpeculativeLaunching {
    func wantsInterimTranscripts() -> Bool { false }
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

    @Published private(set) var activity: Activity?
    @Published private(set) var listening: Listening?

    private final class Session {
        let id: String
        var detector: SpeculativeIntentDetector
        var listener: Task<Void, Never>?
        var launch: Task<Result<NativeLaunchedApp, Error>, Never>?

        init(id: String, detector: SpeculativeIntentDetector) {
            self.id = id
            self.detector = detector
        }
    }

    private let settings: AppSettings
    private let source: (any PartialTranscriptSource)?
    private let inventory: InstalledAppInventory
    private let launcher: any NativeAppLaunching
    private let audit: ActionAuditStore
    private let stabilityThreshold: Int
    private var session: Session?
    private var prepared = false

    init(
        settings: AppSettings = .shared,
        source: (any PartialTranscriptSource)? = PartialTranscriptSources.make(),
        inventory: InstalledAppInventory = .shared,
        launcher: any NativeAppLaunching = NativeActionExecutor.shared,
        audit: ActionAuditStore = .shared,
        stabilityThreshold: Int = 2
    ) {
        self.settings = settings
        self.source = source
        self.inventory = inventory
        self.launcher = launcher
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
        let detector = SpeculativeIntentDetector(environment: inventory.detectorEnvironment, stabilityThreshold: stabilityThreshold)
        let session = Session(id: sessionID, detector: detector)
        self.session = session
        listening = Listening(sessionID: sessionID, transcript: "")
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
                    if self.isEnabled, let commit = session.detector.observe(partial) {
                        self.launch(commit, in: session)
                    }
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
        activity = nil
        listening = nil
        guard let commit = session.detector.commit, let launch = session.launch else { return nil }
        return SpeculativeLaunch(commit: commit, disagreement: session.detector.disagreement, outcome: launch)
    }

    private func launch(_ commit: SpeculativeCommit, in session: Session) {
        let app = commit.action.app
        activity = .launching(app.name)
        speculativeLog.info("Speculative \(String(describing: commit.reason), privacy: .public) launch of \(app.name, privacy: .public)")
        let launcher = self.launcher
        session.launch = Task { @MainActor [weak self] in
            let outcome: Result<NativeLaunchedApp, Error>
            do {
                outcome = .success(try await launcher.launch(applicationAt: app.url))
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
        activity = nil
        listening = nil
    }
}

extension SpeculativeAction {
    var isActivation: Bool {
        if case .activate = self { return true }
        return false
    }
}
