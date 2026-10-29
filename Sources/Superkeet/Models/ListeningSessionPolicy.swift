import Foundation

/// Pure decisions behind the listening session: when a pause ends an utterance, when the next
/// take starts, and what pressing the shortcut again does. The microphone is only open while a
/// session is active; nothing here ever starts one on its own.
enum ListeningSessionPolicy {
    static let endpointSilence: Duration = .milliseconds(900)

    /// Wall time an interim-text ending must hold still to end a take that has had no tick. The
    /// engine decodes every 0.5 s of audio and sends a partial only when the text changes, so this
    /// ends the take after one decode with no new words; the next decode re-encodes a longer tail
    /// and finishes after the timer fires.
    static let fallbackEndpointTimeout: Duration = .milliseconds(1_000)

    static let progressWordCount = 4

    /// What counts as new speech. On a long take the engine re-decodes the whole tail every tick,
    /// so the text keeps flickering while the speaker is silent ("hello" / "hello.", "x dot com" /
    /// "x.com", a revised word near the start). Only the last few words, case and punctuation
    /// aside, say whether anything new was heard.
    static func progressKey(for transcript: String) -> String {
        let words = transcript.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .suffix(progressWordCount)
        return words.joined(separator: " ")
    }

    static let maximumConsecutiveFailures = 2

    enum EndAction: Equatable {
        case stopAndDispatch
        case cancel
        case none
    }

    static func endAction(isRecording: Bool, startPending: Bool, hasSpeech: Bool, dispatchPending: Bool) -> EndAction {
        if isRecording { return hasSpeech && dispatchPending ? .stopAndDispatch : .cancel }
        return startPending ? .cancel : .none
    }

    static func shouldArmEndpoint(transcript: String) -> Bool {
        !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    enum RearmAction: Equatable {
        case rearm
        case wait
        case endSession
    }

    static func rearmAction(daemonState: ParakeetService.DaemonState, isRecording: Bool, startPending: Bool) -> RearmAction {
        switch daemonState {
        case .idle: return isRecording || startPending ? .wait : .rearm
        case .stopped: return .endSession
        case .starting, .recording, .transcribing, .stopping: return .wait
        }
    }

    enum OutcomeAction: Equatable {
        case keepListening
        case endSession
    }

    static func action(after outcome: TranscriptOutcome, consecutiveFailures: Int) -> OutcomeAction {
        guard outcome == .failed else { return .keepListening }
        return consecutiveFailures >= maximumConsecutiveFailures ? .endSession : .keepListening
    }
}

struct TakeEndpoint {
    enum Effect: Equatable {
        case none
        case restartTimer
        case cancelTimer
        case endTake
    }

    private enum Clock {
        case wall(heardEndings: Set<String>, timerRunning: Bool)
        case audio
    }

    let sessionID: String
    private(set) var transcript = ""
    private var clock = Clock.wall(heardEndings: [], timerRunning: false)

    init(sessionID: String) {
        self.sessionID = sessionID
    }

    var hasSpeech: Bool { ListeningSessionPolicy.shouldArmEndpoint(transcript: transcript) }

    mutating func hear(_ text: String) -> Effect {
        guard text != transcript else { return .none }
        transcript = text
        guard case .wall(var heardEndings, let timerRunning) = clock else { return .none }
        guard hasSpeech else {
            clock = .wall(heardEndings: heardEndings, timerRunning: false)
            return .cancelTimer
        }
        let isNewSpeech = heardEndings.insert(ListeningSessionPolicy.progressKey(for: text)).inserted
        clock = .wall(heardEndings: heardEndings, timerRunning: true)
        return isNewSpeech || !timerRunning ? .restartTimer : .none
    }

    mutating func hear(_ tick: EngineTick) -> Effect {
        guard tick.sessionID == sessionID else { return .none }
        clock = .audio
        return hasSpeech && tick.trailingSilence >= ListeningSessionPolicy.endpointSilence ? .endTake : .cancelTimer
    }

    mutating func timerFired() -> Effect {
        guard case .wall(let heardEndings, timerRunning: true) = clock else { return .none }
        clock = .wall(heardEndings: heardEndings, timerRunning: false)
        return hasSpeech ? .endTake : .none
    }
}
