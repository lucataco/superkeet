import Foundation

/// Pure decisions behind the listening session: when a pause ends an utterance, when the next
/// take starts, and what pressing the shortcut again does. The microphone is only open while a
/// session is active; nothing here ever starts one on its own.
enum ListeningSessionPolicy {
    /// Interim text arrives every 0.5 s of speech (0.75 s before parakeet-cli 0.1.9), so an ending
    /// that has not moved for this long (two missed ticks) means the speaker paused. Shorter
    /// would cut sentences at a slow engine tick; longer adds directly to the time before the
    /// action runs. Most actions no longer wait for it: a safe last clause runs once it holds
    /// still (`SpeculativeStepDetector.trailingHold`).
    static let endpointSilence: Duration = .milliseconds(1_000)

    /// Words at the end of the running transcript that identify where the speaker has got to.
    static let progressWordCount = 4

    /// What counts as new speech. On a long take the engine re-decodes the whole tail every tick,
    /// so the text keeps flickering while the speaker is silent ("hello" / "hello.", "x dot com" /
    /// "x.com", a revised word near the start). Only the last few words, case and punctuation
    /// aside, say whether anything new was heard; the controller treats an ending it has already
    /// seen in this take as no progress.
    static func progressKey(for transcript: String) -> String {
        let words = transcript.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .suffix(progressWordCount)
        return words.joined(separator: " ")
    }

    /// Consecutive failed takes before the session gives up rather than looping on a broken engine.
    static let maximumConsecutiveFailures = 2

    enum EndAction: Equatable {
        /// Finish the take and run what was said.
        case stopAndDispatch
        /// Drop the take (nothing said, or the user asked to abandon it).
        case cancel
        case none
    }

    static func endAction(isRecording: Bool, startPending: Bool, hasSpeech: Bool, dispatchPending: Bool) -> EndAction {
        if isRecording { return hasSpeech && dispatchPending ? .stopAndDispatch : .cancel }
        return startPending ? .cancel : .none
    }

    /// Only text worth acting on arms the pause timer; silence from the start keeps listening.
    static func shouldArmEndpoint(transcript: String) -> Bool {
        !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func shouldDispatch(transcript: String, isRecording: Bool, sessionActive: Bool) -> Bool {
        sessionActive && isRecording && shouldArmEndpoint(transcript: transcript)
    }

    enum RearmAction: Equatable {
        case rearm
        case wait
        case endSession
    }

    /// The engine returns to idle once a take's transcript is delivered; that is the moment to
    /// open the microphone again. An engine that stopped altogether ends the session.
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
