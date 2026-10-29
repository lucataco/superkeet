import Combine
import Foundation
import os.log

private let sessionLog = Logger(subsystem: "com.superkeet.app", category: "ListeningSession")

@MainActor
final class ListeningSessionController: ObservableObject {
    static let shared = ListeningSessionController()

    struct Hooks {
        var startRecording: @MainActor () -> Void
        var stopRecording: @MainActor () -> Void
        var stopForNextTake: (@MainActor () -> Void)?
        var cancelRecording: @MainActor () -> Void
        var isRecording: @MainActor () -> Bool
        var isStartPending: @MainActor () -> Bool
        var playSound: @MainActor (CaptureSoundPlayer.Event) -> Void
        var forgetContext: @MainActor () -> Void = {}
    }

    struct Streams {
        var listening: AnyPublisher<SpeculativeLaunchCoordinator.Listening?, Never>
        var ticks: AnyPublisher<EngineTick, Never>
        var daemonState: AnyPublisher<ParakeetService.DaemonState, Never>
        var outcome: AnyPublisher<TranscriptOutcomeEvent?, Never>
    }

    @Published private(set) var isActive = false
    @Published private(set) var dispatchedCommands = 0

    private let settings: AppSettings
    private let hooks: Hooks
    private let fallbackEndpointTimeout: Duration
    private let tickStallTimeout: Duration
    private var cancellables: Set<AnyCancellable> = []
    private var take: TakeEndpoint?
    private var endpointTimer: Task<Void, Never>?
    private var consecutiveFailures = 0
    private var lastOutcomeID: UUID?

    init(
        settings: AppSettings = .shared,
        hooks: Hooks? = nil,
        streams: Streams? = nil,
        fallbackEndpointTimeout: Duration = ListeningSessionPolicy.fallbackEndpointTimeout,
        tickStallTimeout: Duration = ListeningSessionPolicy.tickStallTimeout
    ) {
        self.settings = settings
        self.hooks = hooks ?? Self.defaultHooks()
        self.fallbackEndpointTimeout = fallbackEndpointTimeout
        self.tickStallTimeout = tickStallTimeout
        observe(streams ?? Self.defaultStreams())
    }

    private static func defaultHooks() -> Hooks {
        Hooks(
            startRecording: { MenuBarManager.shared.startCommandRecording() },
            stopRecording: { MenuBarManager.shared.stopRecordingOnly() },
            stopForNextTake: { MenuBarManager.shared.stopRecordingOnly(keepMicWarm: true) },
            cancelRecording: { MenuBarManager.shared.cancelRecordingOnly() },
            isRecording: { AppSettings.shared.isRecording },
            isStartPending: { MenuBarManager.shared.isRecordingStartPending },
            playSound: { CaptureSoundPlayer.play($0) },
            forgetContext: { AgentSessionController.shared.forgetCarriedContext() }
        )
    }

    private static func defaultStreams() -> Streams {
        Streams(
            listening: SpeculativeLaunchCoordinator.shared.$listening.eraseToAnyPublisher(),
            ticks: ParakeetService.shared.ticks.eraseToAnyPublisher(),
            daemonState: ParakeetService.shared.$daemonState.eraseToAnyPublisher(),
            outcome: ParakeetService.shared.$lastOutcome.eraseToAnyPublisher()
        )
    }

    func toggle() {
        dispatchPrecondition(condition: .onQueue(.main))
        if isActive {
            end(dispatchPending: true)
        } else {
            begin()
        }
    }

    func begin() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard settings.actionsEnabled, !isActive else { return }
        isActive = true
        HotkeyManager.shared.noteListeningSessionActive(true)
        consecutiveFailures = 0
        dispatchedCommands = 0
        sessionLog.info("Listening session started")
        hooks.playSound(.start)
        hooks.startRecording()
    }

    func end(dispatchPending: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isActive else { return }
        isActive = false
        HotkeyManager.shared.noteListeningSessionActive(false)
        let action = ListeningSessionPolicy.endAction(
            isRecording: hooks.isRecording(), startPending: hooks.isStartPending(),
            hasSpeech: take?.hasSpeech ?? false, dispatchPending: dispatchPending
        )
        forgetTake()
        switch action {
        case .stopAndDispatch:
            dispatchedCommands += 1
            hooks.stopRecording()
        case .cancel:
            hooks.cancelRecording()
        case .none:
            hooks.playSound(.stop)
        }
        hooks.forgetContext()
        sessionLog.info("Listening session ended (\(String(describing: action), privacy: .public))")
    }

    /// A take that never started brings no engine state change to re-arm on, so the session
    /// would sit on "Listening…" with the microphone closed.
    func startFailed() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isActive else { return }
        sessionLog.warning("A take couldn't start; ending the listening session")
        end(dispatchPending: false)
    }

    private func observe(_ streams: Streams) {
        streams.listening
            .receive(on: DispatchQueue.main)
            .sink { [weak self] listening in self?.listeningChanged(listening) }
            .store(in: &cancellables)
        streams.ticks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tick in self?.tickArrived(tick) }
            .store(in: &cancellables)
        streams.daemonState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.daemonStateChanged(state) }
            .store(in: &cancellables)
        streams.outcome
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.outcomeArrived(event) }
            .store(in: &cancellables)
    }

    private func listeningChanged(_ listening: SpeculativeLaunchCoordinator.Listening?) {
        guard isActive else { return }
        guard let listening else { return forgetTake() }
        if take?.sessionID != listening.sessionID {
            forgetTake()
            take = TakeEndpoint(sessionID: listening.sessionID)
        }
        if let effect = take?.hear(listening.transcript) { apply(effect) }
    }

    private func tickArrived(_ tick: EngineTick) {
        guard isActive, let effect = take?.hear(tick) else { return }
        if effect == .endTake {
            sessionLog.info("The engine measured \(String(describing: tick.trailingSilence), privacy: .public) of silence at \(String(describing: tick.audio), privacy: .public) of audio")
        }
        apply(effect)
    }

    private func apply(_ effect: TakeEndpoint.Effect) {
        switch effect {
        case .none:
            break
        case .startTimer(let timer):
            endpointTimer?.cancel()
            let timeout = timer == .stall ? tickStallTimeout : fallbackEndpointTimeout
            endpointTimer = Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled, let self else { return }
                self.endpointTimer = nil
                if let effect = self.take?.timerFired() { self.apply(effect) }
            }
        case .cancelTimer:
            endpointTimer?.cancel()
            endpointTimer = nil
        case .endTake:
            endpointTimer?.cancel()
            endpointTimer = nil
            guard hooks.isRecording() else { return }
            sessionLog.info("Pause detected; dispatching the utterance")
            dispatchedCommands += 1
            (hooks.stopForNextTake ?? hooks.stopRecording)()
        }
    }

    private func forgetTake() {
        endpointTimer?.cancel()
        endpointTimer = nil
        take = nil
    }

    private func daemonStateChanged(_ state: ParakeetService.DaemonState) {
        guard isActive else { return }
        switch ListeningSessionPolicy.rearmAction(daemonState: state, isRecording: hooks.isRecording(), startPending: hooks.isStartPending()) {
        case .rearm:
            hooks.startRecording()
        case .endSession:
            sessionLog.warning("Speech engine stopped; ending the listening session")
            end(dispatchPending: false)
        case .wait:
            break
        }
    }

    private func outcomeArrived(_ event: TranscriptOutcomeEvent?) {
        guard isActive, let event, event.id != lastOutcomeID else { return }
        lastOutcomeID = event.id
        consecutiveFailures = event.outcome == .failed ? consecutiveFailures + 1 : 0
        if ListeningSessionPolicy.action(after: event.outcome, consecutiveFailures: consecutiveFailures) == .endSession {
            sessionLog.warning("\(self.consecutiveFailures) takes failed in a row; ending the listening session")
            end(dispatchPending: false)
        }
    }
}
