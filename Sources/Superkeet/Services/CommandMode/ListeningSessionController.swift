import Combine
import Foundation
import os.log

private let sessionLog = Logger(subsystem: "com.superkeet.app", category: "ListeningSession")

/// One press of the Actions shortcut opens a listening session: the microphone stays open, each
/// utterance is dispatched as its own command when the speaker pauses, and the HUD pill stays up
/// between commands. Pressing the shortcut again (or Escape) closes the session and releases the
/// microphone. Nothing listens outside a session.
@MainActor
final class ListeningSessionController: ObservableObject {
    static let shared = ListeningSessionController()

    struct Hooks {
        var startRecording: @MainActor () -> Void
        var stopRecording: @MainActor () -> Void
        var cancelRecording: @MainActor () -> Void
        var isRecording: @MainActor () -> Bool
        var isStartPending: @MainActor () -> Bool
        var playSound: @MainActor (CaptureSoundPlayer.Event) -> Void
        /// The app carried from one utterance to the next belongs to the session; drop it at the end.
        var forgetContext: @MainActor () -> Void = {}
    }

    struct Streams {
        /// The running interim text of the current take; nil while no take is listening.
        var transcript: AnyPublisher<String?, Never>
        var daemonState: AnyPublisher<ParakeetService.DaemonState, Never>
        var outcome: AnyPublisher<TranscriptOutcomeEvent?, Never>
    }

    @Published private(set) var isActive = false
    /// Utterances handed to the command runner during this session; the HUD shows a count.
    @Published private(set) var dispatchedCommands = 0

    private let settings: AppSettings
    private let hooks: Hooks
    private let endpointSilence: Duration
    private var cancellables: Set<AnyCancellable> = []
    private var endpointTimer: Task<Void, Never>?
    private var consecutiveFailures = 0
    private var currentTranscript = ""
    private var lastOutcomeID: UUID?

    init(
        settings: AppSettings = .shared,
        hooks: Hooks? = nil,
        streams: Streams? = nil,
        endpointSilence: Duration = ListeningSessionPolicy.endpointSilence
    ) {
        self.settings = settings
        self.hooks = hooks ?? Self.defaultHooks()
        self.endpointSilence = endpointSilence
        observe(streams ?? Self.defaultStreams())
    }

    private static func defaultHooks() -> Hooks {
        Hooks(
            startRecording: { MenuBarManager.shared.startCommandRecording() },
            stopRecording: { MenuBarManager.shared.stopRecordingOnly() },
            cancelRecording: { MenuBarManager.shared.cancelRecordingOnly() },
            isRecording: { AppSettings.shared.isRecording },
            isStartPending: { MenuBarManager.shared.isRecordingStartPending },
            playSound: { CaptureSoundPlayer.play($0) },
            forgetContext: { AgentSessionController.shared.forgetCarriedContext() }
        )
    }

    private static func defaultStreams() -> Streams {
        Streams(
            transcript: SpeculativeLaunchCoordinator.shared.$listening.map { $0?.transcript }.eraseToAnyPublisher(),
            daemonState: ParakeetService.shared.$daemonState.eraseToAnyPublisher(),
            outcome: ParakeetService.shared.$lastOutcome.eraseToAnyPublisher()
        )
    }

    /// The shortcut opens or closes a session; closing it runs whatever was being said.
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
        currentTranscript = ""
        dispatchedCommands = 0
        sessionLog.info("Listening session started")
        hooks.playSound(.start)
        hooks.startRecording()
    }

    /// Closes the session. With `dispatchPending`, speech already captured still runs; without it
    /// (Escape), the take is dropped.
    func end(dispatchPending: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isActive else { return }
        endpointTimer?.cancel()
        endpointTimer = nil
        isActive = false
        HotkeyManager.shared.noteListeningSessionActive(false)
        let action = ListeningSessionPolicy.endAction(
            isRecording: hooks.isRecording(), startPending: hooks.isStartPending(),
            hasSpeech: ListeningSessionPolicy.shouldArmEndpoint(transcript: currentTranscript), dispatchPending: dispatchPending
        )
        currentTranscript = ""
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

    private func observe(_ streams: Streams) {
        streams.transcript
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transcript in self?.transcriptChanged(transcript) }
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

    private func transcriptChanged(_ transcript: String?) {
        guard isActive else { return }
        guard let transcript else {
            currentTranscript = ""
            endpointTimer?.cancel()
            endpointTimer = nil
            return
        }
        guard transcript != currentTranscript else { return }
        currentTranscript = transcript
        endpointTimer?.cancel()
        endpointTimer = nil
        guard ListeningSessionPolicy.shouldArmEndpoint(transcript: transcript) else { return }
        let silence = endpointSilence
        endpointTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: silence)
            guard !Task.isCancelled, let self else { return }
            self.endpointReached(transcript)
        }
    }

    private func endpointReached(_ transcript: String) {
        guard isActive, currentTranscript == transcript,
              ListeningSessionPolicy.shouldDispatch(transcript: transcript, isRecording: hooks.isRecording(), sessionActive: isActive) else { return }
        sessionLog.info("Pause detected; dispatching the utterance")
        dispatchedCommands += 1
        hooks.stopRecording()
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
