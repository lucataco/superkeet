import Foundation
import os.log

private let speculativeLog = Logger(subsystem: "com.superkeet.app", category: "SpeculativeLaunch")

/// What an early launch produced, handed to the command that follows it.
struct SpeculativeLaunchResult: Equatable, Sendable {
    let commit: SpeculativeCommit
    /// The app as macOS reported it, or `nil` when the launch failed.
    let launched: NativeLaunchedApp?
    let failure: String?
    /// Whether later interim text named a different app than the one launched.
    let disagreement: Bool

    var action: SpeculativeAction { commit.action }
    var appName: String { launched?.name ?? commit.action.app.name }
}

/// A launch that may still be in flight when the final transcript arrives.
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

/// The recording lifecycle hooks the speech service calls.
@MainActor
protocol SpeculativeLaunching: AnyObject {
    /// Whether anything would act on interim text right now, so the speech
    /// engine only does the extra work of producing it when it is wanted.
    func wantsInterimTranscripts() -> Bool
    /// A Command Mode recording started; begin listening for an early launch.
    func begin(sessionID: String)
    /// The recording was cancelled or failed; stop listening and discard state.
    func end(sessionID: String)
    /// The final transcript arrived; stop listening and hand over any launch.
    func take(sessionID: String) -> SpeculativeLaunch?
}

extension SpeculativeLaunching {
    func wantsInterimTranscripts() -> Bool { false }
}

/// Listens to interim speech during a Command Mode recording and opens or
/// activates an app the moment the detector is confident, without waiting for
/// the final transcript or the approval HUD. Only installed apps can be named,
/// so the worst outcome of a mishear is an unwanted app window; the final
/// transcript still drives the real command, which reuses this launch instead
/// of repeating it.
@MainActor
final class SpeculativeLaunchCoordinator: ObservableObject, SpeculativeLaunching {
    static let shared = SpeculativeLaunchCoordinator()

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

    var activeSessionID: String? { session?.id }

    func wantsInterimTranscripts() -> Bool { isEnabled }

    func availability() async -> PartialTranscriptAvailability {
        guard let source else { return .requiresNewerOS }
        return await source.availability()
    }

    /// Which recogniser the next recording would use for interim text.
    func recognizerName() async -> String? {
        guard let source else { return nil }
        if let preferred = source as? PreferredPartialSource {
            return await preferred.preferredSource()?.displayName
        }
        return await source.availability().isAvailable ? source.displayName : nil
    }

    /// Downloads the on-device speech model at the user's request, then
    /// finishes preparation so the next recording can use it.
    func installAssets() async throws {
        guard let source else { throw SpeechAnalyzerEngineError.notAvailable(.requiresNewerOS) }
        try await source.installAssets()
        await prepare()
    }

    /// Reserves speech assets, loads the recogniser, and scans installed apps
    /// so the first recording after launch reacts as quickly as later ones.
    func prepare() async {
        guard isEnabled, let source else { return }
        inventory.refresh()
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

    // MARK: SpeculativeLaunching

    func begin(sessionID: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isEnabled, let source else { return }
        discardSession()
        inventory.refresh()
        let detector = SpeculativeIntentDetector(environment: inventory.detectorEnvironment, stabilityThreshold: stabilityThreshold)
        let session = Session(id: sessionID, detector: detector)
        self.session = session
        session.listener = Task { @MainActor [weak self] in
            do {
                let partials = try await source.start(sessionID: sessionID)
                guard let self, self.session === session else {
                    source.stop()
                    return
                }
                for await partial in partials {
                    guard self.session === session else { break }
                    if let commit = session.detector.observe(partial) {
                        self.launch(commit, in: session)
                    }
                }
            } catch is CancellationError {
                // The recording ended before recognition started.
            } catch {
                speculativeLog.error("Live recognition did not start: \(error.localizedDescription, privacy: .public)")
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
        guard let commit = session.detector.commit, let launch = session.launch else { return nil }
        return SpeculativeLaunch(commit: commit, disagreement: session.detector.disagreement, outcome: launch)
    }

    // MARK: Launching

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

    /// Stops listening. A launch already in flight is left to finish: the open
    /// request has been handed to macOS, so cancelling would only misreport it.
    private func discardSession() {
        guard let session else { return }
        self.session = nil
        source?.stop()
        session.listener?.cancel()
        activity = nil
    }
}

extension SpeculativeAction {
    var isActivation: Bool {
        if case .activate = self { return true }
        return false
    }
}
