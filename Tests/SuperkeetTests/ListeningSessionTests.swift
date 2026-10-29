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
    }

    func testFallbackPauseIsLongerThanAnEngineTickAndShorterThanASentenceGap() {
        XCTAssertGreaterThan(ListeningSessionPolicy.fallbackEndpointTimeout, .milliseconds(750))
        XCTAssertLessThanOrEqual(ListeningSessionPolicy.fallbackEndpointTimeout, .milliseconds(1_500))
    }

    func testFallbackTimerRestartsOnNewEndingsAndWhenStopped() {
        var take = TakeEndpoint(sessionID: "take")
        XCTAssertEqual(take.hear("open x.com"), .startTimer(.progress))
        XCTAssertEqual(take.hear("Open x.com."), .none, "A re-decode of words already heard is no progress.")
        XCTAssertEqual(take.hear(""), .cancelTimer)
        XCTAssertEqual(take.hear("open x.com"), .startTimer(.progress), "An ending already heard re-arms a stopped timer.")
        XCTAssertEqual(take.timerFired(), .endTake)
    }

    private func tick(_ take: String = "take", audio: Int = 1_000, silence: Int = 0) -> EngineTick {
        EngineTick(sessionID: take, audio: .milliseconds(audio), trailingSilence: .milliseconds(silence))
    }

    func testTheFirstTickHandsTheDecisionToTheStallTimer() {
        var take = TakeEndpoint(sessionID: "take")
        XCTAssertEqual(take.hear("open TextEdit"), .startTimer(.progress))
        XCTAssertEqual(take.hear(tick()), .startTimer(.stall), "The tick replaces the progress timer.")
        XCTAssertEqual(take.hear("open TextEdit and make a new document"), .none, "After a tick, new words start no timer.")
    }

    func testTicksThatKeepComingNeverFallBack() {
        var take = TakeEndpoint(sessionID: "take")
        _ = take.hear("open TextEdit")
        for index in 1...6 {
            XCTAssertEqual(take.hear(tick(audio: index * 500, silence: 200)), .startTimer(.stall), "Every tick restarts the stall timer.")
        }
        XCTAssertEqual(take.hear(tick(audio: 3_500, silence: 900)), .endTake)
    }

    func testATakeWhoseTicksStallEndsOnTheProgressTimer() {
        var take = TakeEndpoint(sessionID: "take")
        _ = take.hear("open TextEdit")
        _ = take.hear(tick())
        XCTAssertEqual(take.timerFired(), .startTimer(.progress), "No tick for the stall timeout hands the take back to the wall clock.")
        XCTAssertEqual(take.hear("open TextEdit"), .none)
        XCTAssertEqual(take.timerFired(), .endTake)
        XCTAssertEqual(take.timerFired(), .none, "The take ends once.")
    }

    func testAStalledTakeThatHearsNewWordsKeepsWaiting() {
        var take = TakeEndpoint(sessionID: "take")
        _ = take.hear("open TextEdit")
        _ = take.hear(tick())
        XCTAssertEqual(take.timerFired(), .startTimer(.progress))
        XCTAssertEqual(take.hear("open TextEdit and make a new document"), .startTimer(.progress), "New words restart the progress timer.")
        XCTAssertEqual(take.hear("Open TextEdit and make a new document."), .none, "A re-decode is no progress.")
        XCTAssertEqual(take.timerFired(), .endTake)
    }

    func testAStalledTakeCanReturnToTicks() {
        var take = TakeEndpoint(sessionID: "take")
        _ = take.hear("open TextEdit")
        _ = take.hear(tick())
        _ = take.timerFired()
        XCTAssertEqual(take.hear(tick(audio: 4_000)), .startTimer(.stall))
        XCTAssertEqual(take.timerFired(), .startTimer(.progress), "Stalling again falls back again.")
    }

    func testAStallBeforeAnySpeechStartsNoTimerUntilWordsArrive() {
        var take = TakeEndpoint(sessionID: "take")
        _ = take.hear(tick(silence: 500))
        XCTAssertEqual(take.timerFired(), .none)
        XCTAssertEqual(take.hear("open"), .startTimer(.progress))
        XCTAssertEqual(take.timerFired(), .endTake)
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

    /// Word timings (start ms, end ms, word) of the three-sentence TTS command that the timer rule
    /// split in 11 of 11 replays. The longest pause is 742 ms, between "document?" and "And".
    private let command: [(start: Int, end: Int, word: String)] = [
        (31, 131, "Can"), (151, 312, "you"), (432, 612, "open"), (652, 732, "up"), (772, 1_213, "TextEdit"),
        (1_253, 1_393, "for"), (1_434, 1_554, "me?"), (2_175, 2_355, "And"), (2_536, 2_676, "once"),
        (2_716, 2_936, "you're"), (3_057, 3_537, "there,"), (3_678, 3_838, "can"), (3_878, 4_038, "you"),
        (4_159, 4_479, "create"), (4_539, 4_559, "a"), (4_599, 4_720, "new"), (4_740, 5_120, "document?"),
        (5_862, 5_982, "And"), (6_062, 6_262, "let's"), (6_322, 6_483, "make"), (6_543, 6_643, "the"),
        (6_703, 7_084, "title"), (7_164, 7_545, "say"), (7_745, 8_066, "Hello.")
    ]

    func testReplayingTheCommandAtEveryTickPhaseNeverSplitsItAndEndsAfterTheLastWord() {
        let lastWordEnd = 8_066
        let recogniserLag = 600
        for pad in stride(from: 0, through: 500, by: 50) {
            var take = TakeEndpoint(sessionID: "take")
            var endedAt: Int?
            for audio in stride(from: 500, through: 14_000, by: 500) {
                let clock = audio - pad
                let heard = command.filter { $0.end + recogniserLag <= clock }.map(\.word).joined(separator: " ")
                _ = take.hear(heard)
                let lastSpeechEnd = command.last { $0.start <= clock }.map { min($0.end, clock) } ?? 0
                let isSpeaking = command.contains { $0.start <= clock && clock < $0.end }
                let silence = isSpeaking ? 0 : clock - lastSpeechEnd
                let tick = EngineTick(sessionID: "take", audio: .milliseconds(audio), trailingSilence: .milliseconds(silence))
                if take.hear(tick) == .endTake {
                    endedAt = clock
                    break
                }
            }
            guard let endedAt else { return XCTFail("The take never ended at pad \(pad) ms.") }
            XCTAssertGreaterThanOrEqual(endedAt - lastWordEnd, 900, "Ended inside a pause at pad \(pad) ms.")
            XCTAssertLessThanOrEqual(endedAt - lastWordEnd, 1_400, "Waited more than one tick past the endpoint at pad \(pad) ms.")
        }
    }
}

@MainActor
final class ListeningSessionControllerTests: XCTestCase {
    private final class Recorder {
        var starts = 0
        var stops = 0
        var warmStops = 0
        var cancels = 0
        var sounds: [CaptureSoundPlayer.Event] = []
        var recording = false
        var startPending = false
        var forgets = 0
    }

    private struct Fixture {
        let controller: ListeningSessionController
        let recorder: Recorder
        let listening: CurrentValueSubject<SpeculativeLaunchCoordinator.Listening?, Never>
        let ticks: PassthroughSubject<EngineTick, Never>
        let daemonState: CurrentValueSubject<ParakeetService.DaemonState, Never>
        let outcome: CurrentValueSubject<TranscriptOutcomeEvent?, Never>

        func hear(_ transcript: String, take: String = "take-1") {
            listening.send(.init(sessionID: take, transcript: transcript))
        }

        func takeEnded() {
            listening.send(nil)
        }

        func tick(silence: Int, audio: Int = 6_000, take: String = "take-1") {
            ticks.send(EngineTick(sessionID: take, audio: .milliseconds(audio), trailingSilence: .milliseconds(silence)))
        }
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

    private func makeFixture(fallbackTimeout: Duration = .milliseconds(60), stallTimeout: Duration = .seconds(5)) -> Fixture {
        let recorder = Recorder()
        let listening = CurrentValueSubject<SpeculativeLaunchCoordinator.Listening?, Never>(nil)
        let ticks = PassthroughSubject<EngineTick, Never>()
        let daemonState = CurrentValueSubject<ParakeetService.DaemonState, Never>(.idle)
        let outcome = CurrentValueSubject<TranscriptOutcomeEvent?, Never>(nil)
        let hooks = ListeningSessionController.Hooks(
            startRecording: { recorder.starts += 1; recorder.recording = true },
            stopRecording: { recorder.stops += 1; recorder.recording = false },
            stopForNextTake: { recorder.stops += 1; recorder.warmStops += 1; recorder.recording = false },
            cancelRecording: { recorder.cancels += 1; recorder.recording = false },
            isRecording: { recorder.recording },
            isStartPending: { recorder.startPending },
            playSound: { recorder.sounds.append($0) },
            forgetContext: { recorder.forgets += 1 }
        )
        let streams = ListeningSessionController.Streams(
            listening: listening.eraseToAnyPublisher(),
            ticks: ticks.eraseToAnyPublisher(),
            daemonState: daemonState.eraseToAnyPublisher(),
            outcome: outcome.eraseToAnyPublisher()
        )
        let controller = ListeningSessionController(settings: .shared, hooks: hooks, streams: streams, fallbackEndpointTimeout: fallbackTimeout, tickStallTimeout: stallTimeout)
        return Fixture(controller: controller, recorder: recorder, listening: listening, ticks: ticks, daemonState: daemonState, outcome: outcome)
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
        let fixture = makeFixture(fallbackTimeout: .milliseconds(250))
        fixture.controller.begin()
        fixture.hear("")
        fixture.hear("open")
        await settle(.milliseconds(40))
        fixture.hear("open Notes")
        await settle(.milliseconds(40))
        XCTAssertEqual(fixture.recorder.stops, 0, "Text still changing; no dispatch yet.")
        await settle(.milliseconds(300))
        XCTAssertEqual(fixture.recorder.stops, 1, "Unchanged text for the pause length ends the take.")
        XCTAssertEqual(fixture.recorder.warmStops, 1, "A pause keeps the microphone warm for the next take.")
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
        let fixture = makeFixture(fallbackTimeout: .milliseconds(400))
        fixture.controller.begin()
        let readings = ["can you open up x.com?", "can you open up x dot com.", "Can you open up x dot com", "can you open up x.com"]
        let deadline = ContinuousClock.now + .milliseconds(3_000)
        var index = 0
        while fixture.recorder.stops == 0, ContinuousClock.now < deadline {
            fixture.hear(readings[index % readings.count])
            index += 1
            await settle(.milliseconds(40))
        }
        XCTAssertEqual(fixture.recorder.stops, 1, "Only new words restart the pause timer.")
        fixture.controller.end(dispatchPending: false)
    }

    func testAPauseBetweenSentencesOfOneCommandKeepsTheTakeOpen() async {
        let fixture = makeFixture()
        fixture.controller.begin()
        fixture.hear("")
        fixture.tick(silence: 500, audio: 500)
        fixture.hear("Can you open TextEdit and make a new document?")
        for silence in [0, 230, 740] {
            fixture.tick(silence: silence)
            await settle(.milliseconds(100))
        }
        XCTAssertEqual(fixture.recorder.stops, 0, "A 742 ms pause between sentences is still one command.")
        fixture.hear("Can you open TextEdit and make a new document? And let's make the title say hello.")
        await settle(.milliseconds(100))
        XCTAssertEqual(fixture.recorder.stops, 0, "Once ticks arrive, new words no longer start the wall-clock fallback.")
        fixture.tick(silence: 0)
        fixture.tick(silence: 900)
        await settle()
        XCTAssertEqual(fixture.recorder.stops, 1, "900 ms of measured silence after speech ends the take.")
        XCTAssertEqual(fixture.recorder.warmStops, 1, "A pause keeps the microphone warm for the next take.")
        XCTAssertEqual(fixture.controller.dispatchedCommands, 1)
        XCTAssertTrue(fixture.controller.isActive)
        fixture.controller.end(dispatchPending: false)
    }

    func testATakeWhoseTicksStopEndsOnTheWallClockRule() async {
        let fixture = makeFixture(fallbackTimeout: .milliseconds(80), stallTimeout: .milliseconds(100))
        fixture.controller.begin()
        fixture.hear("open Notes")
        fixture.tick(silence: 0)
        await settle(.milliseconds(60))
        XCTAssertEqual(fixture.recorder.stops, 0, "Ticks arrived recently.")
        await settle(.milliseconds(400))
        XCTAssertEqual(fixture.recorder.stops, 1, "No tick for the stall timeout hands the take to the progress timer, which ends it.")
        XCTAssertEqual(fixture.recorder.warmStops, 1)
        XCTAssertEqual(fixture.controller.dispatchedCommands, 1)
        fixture.controller.end(dispatchPending: false)
    }

    func testTicksThatKeepComingNeverTriggerTheFallback() async {
        let fixture = makeFixture(fallbackTimeout: .milliseconds(50), stallTimeout: .milliseconds(150))
        fixture.controller.begin()
        fixture.hear("open Notes")
        for _ in 0..<8 {
            fixture.tick(silence: 300)
            await settle(.milliseconds(60))
        }
        XCTAssertEqual(fixture.recorder.stops, 0, "Ticks every 60 ms never let the 150 ms stall timer fire.")
        fixture.controller.end(dispatchPending: false)
    }

    func testAStalledTakeThatHearsNewWordsKeepsWaiting() async {
        let fixture = makeFixture(fallbackTimeout: .milliseconds(250), stallTimeout: .milliseconds(50))
        fixture.controller.begin()
        fixture.hear("open Notes")
        fixture.tick(silence: 0)
        await settle(.milliseconds(100))
        fixture.hear("open Notes and make a new note")
        await settle(.milliseconds(150))
        XCTAssertEqual(fixture.recorder.stops, 0, "New words restarted the progress timer.")
        await settle(.milliseconds(300))
        XCTAssertEqual(fixture.recorder.stops, 1)
        fixture.controller.end(dispatchPending: false)
    }

    func testMeasuredSilenceBeforeAnySpeechNeverEndsTheTake() async {
        let fixture = makeFixture()
        fixture.controller.begin()
        fixture.hear("")
        for audio in [500, 1_000, 1_500, 3_000] {
            fixture.tick(silence: audio, audio: audio)
        }
        await settle(.milliseconds(120))
        XCTAssertEqual(fixture.recorder.stops, 0)
        XCTAssertTrue(fixture.controller.isActive)
        fixture.hear("open Notes")
        fixture.tick(silence: 0, audio: 3_500)
        fixture.tick(silence: 1_000, audio: 4_500)
        await settle()
        XCTAssertEqual(fixture.recorder.stops, 1, "Silence after the first words does end it.")
        fixture.controller.end(dispatchPending: false)
    }

    func testTicksFromAnotherTakeOrAfterRecordingAreIgnored() async {
        let fixture = makeFixture(fallbackTimeout: .seconds(5))
        fixture.controller.begin()
        fixture.hear("open Notes")
        fixture.tick(silence: 2_000, take: "take-0")
        await settle()
        XCTAssertEqual(fixture.recorder.stops, 0, "A late tick from the previous take ends nothing.")
        fixture.recorder.recording = false
        fixture.tick(silence: 2_000)
        await settle()
        XCTAssertEqual(fixture.recorder.stops, 0, "A tick after recording stopped ends nothing.")
        fixture.recorder.recording = true
        fixture.tick(silence: 2_000)
        await settle()
        XCTAssertEqual(fixture.recorder.stops, 1)
        fixture.controller.end(dispatchPending: false)
    }

    func testSilenceFromTheStartKeepsListening() async {
        let fixture = makeFixture()
        fixture.controller.begin()
        fixture.hear("")
        await settle(.milliseconds(120))
        XCTAssertEqual(fixture.recorder.stops, 0)
        XCTAssertTrue(fixture.controller.isActive)
        fixture.controller.end(dispatchPending: false)
    }

    func testEngineBackAtIdleReopensTheMicrophone() async {
        let fixture = makeFixture(fallbackTimeout: .milliseconds(250))
        fixture.controller.begin()
        fixture.hear("open Notes")
        await settle(.milliseconds(400))
        XCTAssertEqual(fixture.recorder.stops, 1)
        fixture.takeEnded()
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
        let fixture = makeFixture(fallbackTimeout: .milliseconds(300))
        fixture.controller.toggle()
        fixture.hear("open Notes")
        await settle()
        fixture.controller.toggle()
        XCTAssertFalse(fixture.controller.isActive)
        XCTAssertEqual(fixture.recorder.stops, 1)
        XCTAssertEqual(fixture.recorder.warmStops, 0, "Closing the session releases the microphone.")
        XCTAssertEqual(fixture.recorder.cancels, 0)
        await settle(.milliseconds(600))
        XCTAssertEqual(fixture.recorder.stops, 1, "The pause timer died with the session.")
        fixture.daemonState.send(.idle)
        await settle()
        XCTAssertEqual(fixture.recorder.starts, 1, "A closed session never reopens the microphone.")
    }

    func testEscapeDropsTheTakeAndCloses() async {
        // Long pause so a slow runner can't end the take before Escape does.
        let fixture = makeFixture(fallbackTimeout: .seconds(5))
        fixture.controller.begin()
        fixture.hear("open Notes")
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
        fixture.hear("")
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

    func testATakeThatCannotStartEndsTheSession() {
        let fixture = makeFixture()
        fixture.controller.begin()
        fixture.recorder.recording = false
        fixture.controller.startFailed()
        XCTAssertFalse(fixture.controller.isActive, "Nothing would re-arm it, so it must not stay on Listening.")
        XCTAssertEqual(fixture.recorder.cancels, 0, "There is no take to cancel.")
        XCTAssertEqual(fixture.recorder.sounds, [.start, .stop])
        XCTAssertEqual(fixture.recorder.forgets, 1)
        fixture.controller.startFailed()
        XCTAssertEqual(fixture.recorder.sounds, [.start, .stop], "A closed session ignores later failures.")
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
