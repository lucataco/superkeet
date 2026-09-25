import Combine
import XCTest
@testable import Superkeet

final class ListeningSessionPolicyTests: XCTestCase {
    func testShortcutWhileSpeakingRunsWhatWasSaid() {
        XCTAssertEqual(ListeningSessionPolicy.endAction(isRecording: true, startPending: false, hasSpeech: true, dispatchPending: true), .stopAndDispatch)
        XCTAssertEqual(ListeningSessionPolicy.endAction(isRecording: true, startPending: false, hasSpeech: false, dispatchPending: true), .cancel)
        XCTAssertEqual(ListeningSessionPolicy.endAction(isRecording: true, startPending: false, hasSpeech: true, dispatchPending: false), .cancel, "Escape drops the take.")
        XCTAssertEqual(ListeningSessionPolicy.endAction(isRecording: false, startPending: true, hasSpeech: false, dispatchPending: true), .cancel)
        XCTAssertEqual(ListeningSessionPolicy.endAction(isRecording: false, startPending: false, hasSpeech: false, dispatchPending: true), .none)
    }

    func testOnlySpeechArmsThePauseTimer() {
        XCTAssertFalse(ListeningSessionPolicy.shouldArmEndpoint(transcript: ""))
        XCTAssertFalse(ListeningSessionPolicy.shouldArmEndpoint(transcript: "  \n"))
        XCTAssertTrue(ListeningSessionPolicy.shouldArmEndpoint(transcript: "open"))
        XCTAssertTrue(ListeningSessionPolicy.shouldDispatch(transcript: "open Notes", isRecording: true, sessionActive: true))
        XCTAssertFalse(ListeningSessionPolicy.shouldDispatch(transcript: "open Notes", isRecording: false, sessionActive: true))
        XCTAssertFalse(ListeningSessionPolicy.shouldDispatch(transcript: "open Notes", isRecording: true, sessionActive: false))
    }

    func testPauseIsLongerThanAnEngineTickAndShorterThanASentenceGap() {
        XCTAssertGreaterThan(ListeningSessionPolicy.endpointSilence, .milliseconds(750))
        XCTAssertLessThanOrEqual(ListeningSessionPolicy.endpointSilence, .milliseconds(1_500))
    }

    func testIdleEngineRearmsUnlessATakeIsAlreadyUnderway() {
        XCTAssertEqual(ListeningSessionPolicy.rearmAction(daemonState: .idle, isRecording: false, startPending: false), .rearm)
        XCTAssertEqual(ListeningSessionPolicy.rearmAction(daemonState: .idle, isRecording: true, startPending: false), .wait)
        XCTAssertEqual(ListeningSessionPolicy.rearmAction(daemonState: .idle, isRecording: false, startPending: true), .wait)
        XCTAssertEqual(ListeningSessionPolicy.rearmAction(daemonState: .transcribing, isRecording: false, startPending: false), .wait)
        XCTAssertEqual(ListeningSessionPolicy.rearmAction(daemonState: .starting, isRecording: false, startPending: false), .wait)
        XCTAssertEqual(ListeningSessionPolicy.rearmAction(daemonState: .stopped, isRecording: false, startPending: false), .endSession)
    }

    func testRepeatedFailuresEndTheSession() {
        XCTAssertEqual(ListeningSessionPolicy.action(after: .failed, consecutiveFailures: 1), .keepListening)
        XCTAssertEqual(ListeningSessionPolicy.action(after: .failed, consecutiveFailures: 2), .endSession)
        for outcome in [TranscriptOutcome.command, .noSpeech, .ignored] {
            XCTAssertEqual(ListeningSessionPolicy.action(after: outcome, consecutiveFailures: 5), .keepListening)
        }
    }
}

@MainActor
final class ListeningSessionControllerTests: XCTestCase {
    private final class Recorder {
        var starts = 0
        var stops = 0
        var cancels = 0
        var sounds: [CaptureSoundPlayer.Event] = []
        var recording = false
        var startPending = false
        var forgets = 0
    }

    private struct Fixture {
        let controller: ListeningSessionController
        let recorder: Recorder
        let transcript: CurrentValueSubject<String?, Never>
        let daemonState: CurrentValueSubject<ParakeetService.DaemonState, Never>
        let outcome: CurrentValueSubject<TranscriptOutcomeEvent?, Never>
    }

    private nonisolated(unsafe) var savedActionsEnabled: Bool?

    override func setUp() {
        super.setUp()
        savedActionsEnabled = AppSettings.shared.actionsEnabled
        AppSettings.shared.actionsEnabled = true
    }

    override func tearDown() {
        if let saved = savedActionsEnabled { AppSettings.shared.actionsEnabled = saved }
        super.tearDown()
    }

    private func makeFixture(silence: Duration = .milliseconds(60)) -> Fixture {
        let recorder = Recorder()
        let transcript = CurrentValueSubject<String?, Never>(nil)
        let daemonState = CurrentValueSubject<ParakeetService.DaemonState, Never>(.idle)
        let outcome = CurrentValueSubject<TranscriptOutcomeEvent?, Never>(nil)
        let hooks = ListeningSessionController.Hooks(
            startRecording: { recorder.starts += 1; recorder.recording = true },
            stopRecording: { recorder.stops += 1; recorder.recording = false },
            cancelRecording: { recorder.cancels += 1; recorder.recording = false },
            isRecording: { recorder.recording },
            isStartPending: { recorder.startPending },
            playSound: { recorder.sounds.append($0) },
            forgetContext: { recorder.forgets += 1 }
        )
        let streams = ListeningSessionController.Streams(
            transcript: transcript.eraseToAnyPublisher(),
            daemonState: daemonState.eraseToAnyPublisher(),
            outcome: outcome.eraseToAnyPublisher()
        )
        let controller = ListeningSessionController(settings: .shared, hooks: hooks, streams: streams, endpointSilence: silence)
        return Fixture(controller: controller, recorder: recorder, transcript: transcript, daemonState: daemonState, outcome: outcome)
    }

    private func settle(_ duration: Duration = .milliseconds(20)) async {
        try? await Task.sleep(for: duration)
    }

    func testBeginOpensTheMicrophoneOnceWithOneSound() async {
        let fixture = makeFixture()
        fixture.controller.begin()
        XCTAssertTrue(fixture.controller.isActive)
        XCTAssertEqual(fixture.recorder.starts, 1)
        XCTAssertEqual(fixture.recorder.sounds, [.start])
        fixture.controller.begin()
        XCTAssertEqual(fixture.recorder.starts, 1, "A second begin is a no-op.")
        fixture.controller.end(dispatchPending: false)
    }

    func testAPauseAfterSpeechDispatchesTheUtterance() async {
        let fixture = makeFixture(silence: .milliseconds(250))
        fixture.controller.begin()
        fixture.transcript.send("")
        fixture.transcript.send("open")
        await settle(.milliseconds(40))
        fixture.transcript.send("open Notes")
        await settle(.milliseconds(40))
        XCTAssertEqual(fixture.recorder.stops, 0, "Text still changing; no dispatch yet.")
        await settle(.milliseconds(300))
        XCTAssertEqual(fixture.recorder.stops, 1, "Unchanged text for the pause length ends the take.")
        XCTAssertEqual(fixture.controller.dispatchedCommands, 1)
        XCTAssertTrue(fixture.controller.isActive, "The session outlives the utterance.")
        fixture.controller.end(dispatchPending: false)
    }

    func testProgressKeyIgnoresCasePunctuationAndEarlierRevisions() {
        XCTAssertEqual(ListeningSessionPolicy.progressKey(for: "? And um inside this new note let's make the title say hello"),
                       ListeningSessionPolicy.progressKey(for: "And um inside this new note, let's make the title say Hello."))
        XCTAssertNotEqual(ListeningSessionPolicy.progressKey(for: "make the title say"),
                          ListeningSessionPolicy.progressKey(for: "make the title say hello"))
    }

    func testReDecodeFlickerDuringAPauseStillEndsTheTake() async {
        // The engine keeps flipping between readings of words already heard, faster than the
        // pause length and for well past it. Only new words may restart the timer, so the take
        // still ends. (Asserting nothing about intermediate timing keeps this stable on slow CI.)
        let fixture = makeFixture(silence: .milliseconds(200))
        fixture.controller.begin()
        let readings = ["can you open up x.com?", "can you open up x dot com.", "Can you open up x dot com", "can you open up x.com"]
        let deadline = ContinuousClock.now + .milliseconds(1_500)
        var index = 0
        while fixture.recorder.stops == 0, ContinuousClock.now < deadline {
            fixture.transcript.send(readings[index % readings.count])
            index += 1
            await settle(.milliseconds(40))
        }
        XCTAssertEqual(fixture.recorder.stops, 1, "Only new words restart the pause timer.")
        XCTAssertGreaterThan(index, 4, "Flicker kept arriving before the pause ended the take.")
        fixture.controller.end(dispatchPending: false)
    }

    func testSilenceFromTheStartKeepsListening() async {
        let fixture = makeFixture()
        fixture.controller.begin()
        fixture.transcript.send("")
        await settle(.milliseconds(120))
        XCTAssertEqual(fixture.recorder.stops, 0)
        XCTAssertTrue(fixture.controller.isActive)
        fixture.controller.end(dispatchPending: false)
    }

    func testEngineBackAtIdleReopensTheMicrophone() async {
        let fixture = makeFixture(silence: .milliseconds(250))
        fixture.controller.begin()
        fixture.transcript.send("open Notes")
        await settle(.milliseconds(400))
        XCTAssertEqual(fixture.recorder.stops, 1)
        fixture.transcript.send(nil)
        fixture.daemonState.send(.transcribing)
        await settle()
        XCTAssertEqual(fixture.recorder.starts, 1, "Not while the engine is still transcribing.")
        fixture.daemonState.send(.idle)
        await settle()
        XCTAssertEqual(fixture.recorder.starts, 2, "The next take starts as soon as the engine is idle.")
        XCTAssertEqual(fixture.recorder.sounds, [.start], "No per-utterance sounds inside a session.")
        fixture.controller.end(dispatchPending: false)
    }

    func testShortcutAgainRunsPendingSpeechAndCloses() async {
        let fixture = makeFixture()
        fixture.controller.toggle()
        fixture.transcript.send("open Notes")
        await settle()
        fixture.controller.toggle()
        XCTAssertFalse(fixture.controller.isActive)
        XCTAssertEqual(fixture.recorder.stops, 1)
        XCTAssertEqual(fixture.recorder.cancels, 0)
        await settle(.milliseconds(120))
        XCTAssertEqual(fixture.recorder.stops, 1, "The pause timer died with the session.")
        fixture.daemonState.send(.idle)
        await settle()
        XCTAssertEqual(fixture.recorder.starts, 1, "A closed session never reopens the microphone.")
    }

    func testEscapeDropsTheTakeAndCloses() async {
        let fixture = makeFixture()
        fixture.controller.begin()
        fixture.transcript.send("open Notes")
        await settle()
        fixture.controller.end(dispatchPending: false)
        XCTAssertEqual(fixture.recorder.cancels, 1)
        XCTAssertEqual(fixture.recorder.stops, 0)
        XCTAssertFalse(fixture.controller.isActive)
        XCTAssertEqual(fixture.recorder.forgets, 1, "The app carried between utterances belongs to the session.")
    }

    func testClosingWithNothingSaidCancelsTheEmptyTake() async {
        let fixture = makeFixture()
        fixture.controller.begin()
        fixture.transcript.send("")
        await settle()
        fixture.controller.toggle()
        XCTAssertEqual(fixture.recorder.cancels, 1)
        XCTAssertEqual(fixture.recorder.stops, 0)
    }

    func testTwoFailedTakesEndTheSessionButOneDoesNot() async {
        let fixture = makeFixture()
        fixture.controller.begin()
        fixture.recorder.recording = false
        fixture.outcome.send(TranscriptOutcomeEvent(.failed))
        await settle()
        XCTAssertTrue(fixture.controller.isActive)
        fixture.outcome.send(TranscriptOutcomeEvent(.ignored))
        await settle()
        fixture.outcome.send(TranscriptOutcomeEvent(.failed))
        await settle()
        XCTAssertTrue(fixture.controller.isActive, "A success in between resets the failure count.")
        fixture.outcome.send(TranscriptOutcomeEvent(.failed))
        await settle()
        XCTAssertFalse(fixture.controller.isActive)
    }

    func testEngineStoppingEndsTheSession() async {
        let fixture = makeFixture()
        fixture.controller.begin()
        fixture.daemonState.send(.stopped)
        await settle()
        XCTAssertFalse(fixture.controller.isActive)
    }

    func testSessionNeedsActionsMode() {
        AppSettings.shared.actionsEnabled = false
        let fixture = makeFixture()
        fixture.controller.begin()
        XCTAssertFalse(fixture.controller.isActive)
        XCTAssertEqual(fixture.recorder.starts, 0)
    }
}
