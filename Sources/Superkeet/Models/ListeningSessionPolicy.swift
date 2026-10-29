import Foundation

/// Pure decisions behind the listening session: when a pause ends an utterance, when the next
/// take starts, and what pressing the shortcut again does. The microphone is only open while a
/// session is active; nothing here ever starts one on its own.
enum ListeningSessionPolicy {
    static let endpointSilence: Duration = .milliseconds(900)

    /// Wall time an interim-text ending must hold still to end a take that has no ticks (or whose ticks stalled). The
    /// engine decodes every 0.5 s of audio and sends a partial only when the text changes, so this
    /// ends the take after one decode with no new words; the next decode re-encodes a longer tail
    /// and finishes after the timer fires.
    static let fallbackEndpointTimeout: Duration = .milliseconds(1_000)

    /// Wall time without a tick (three missed ticks) after which a take that had ticks goes back
    /// to the progress-key timer, because the engine stops sending them for a session whose
    /// silence detector failed.
    static let tickStallTimeout: Duration = .milliseconds(1_500)

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

/// How the controller learns a take is over. `Effect`s tell the controller what to do; the take
/// decides in audio time while ticks keep arriving and in wall time otherwise.
struct TakeEndpoint {
    enum Timer: Equatable {
        /// Wall time without a new ending in the interim text.
        case progress
        /// Wall time without a tick.
        case stall
    }

    enum Effect: Equatable {
        case none
        case startTimer(Timer)
        case cancelTimer
        case endTake
    }

    private enum Clock {
        case wall(heardEndings: Set<String>, timerRunning: Bool)
        case audio(heardEndings: Set<String>)
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
        switch clock {
        case .wall(var heardEndings, let timerRunning):
            guard hasSpeech else {
                clock = .wall(heardEndings: heardEndings, timerRunning: false)
                return .cancelTimer
            }
            let isNewSpeech = heardEndings.insert(ListeningSessionPolicy.progressKey(for: text)).inserted
            clock = .wall(heardEndings: heardEndings, timerRunning: true)
            return isNewSpeech || !timerRunning ? .startTimer(.progress) : .none
        case .audio(var heardEndings):
            if hasSpeech { heardEndings.insert(ListeningSessionPolicy.progressKey(for: text)) }
            clock = .audio(heardEndings: heardEndings)
            return .none
        }
    }

    mutating func hear(_ tick: EngineTick) -> Effect {
        guard tick.sessionID == sessionID else { return .none }
        switch clock {
        case .wall(let heardEndings, _), .audio(let heardEndings):
            clock = .audio(heardEndings: heardEndings)
        }
        return hasSpeech && tick.trailingSilence >= ListeningSessionPolicy.endpointSilence ? .endTake : .startTimer(.stall)
    }

    /// The running timer elapsed. A take whose ticks stopped goes back to the wall-clock rule
    /// for the rest of the take, starting with the words it already has.
    mutating func timerFired() -> Effect {
        switch clock {
        case .wall(let heardEndings, timerRunning: true):
            clock = .wall(heardEndings: heardEndings, timerRunning: false)
            return hasSpeech ? .endTake : .none
        case .audio(let heardEndings):
            clock = .wall(heardEndings: heardEndings, timerRunning: hasSpeech)
            return hasSpeech ? .startTimer(.progress) : .none
        case .wall:
            return .none
        }
    }
}
