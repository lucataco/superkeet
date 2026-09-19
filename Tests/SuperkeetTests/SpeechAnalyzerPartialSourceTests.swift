import AVFoundation
import XCTest
@testable import Superkeet

@MainActor
final class SpeechAnalyzerPartialSourceTests: XCTestCase {
    final class FakeEngine: StreamingSpeechRecognizing, @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: AsyncThrowingStream<RecognizedPhrase, Error>.Continuation?
        private var appendedFrames = 0
        var startCount = 0
        var finishCount = 0
        var startFailure: Error?
        var availabilityResult = PartialTranscriptAvailability.available
        var prewarmCount = 0
        var installCount = 0

        var frames: Int { lock.withLock { appendedFrames } }
        var isStreaming: Bool { lock.withLock { continuation != nil } }

        func availability() async -> PartialTranscriptAvailability { availabilityResult }

        func installAssets() async throws {
            installCount += 1
            availabilityResult = .available
        }

        func prewarm() async { prewarmCount += 1 }

        func start() async throws -> AsyncThrowingStream<RecognizedPhrase, Error> {
            startCount += 1
            if let startFailure { throw startFailure }
            let (stream, continuation) = AsyncThrowingStream.makeStream(of: RecognizedPhrase.self)
            lock.withLock { self.continuation = continuation }
            return stream
        }

        func append(_ buffer: AVAudioPCMBuffer) {
            lock.withLock { appendedFrames += Int(buffer.frameLength) }
        }

        func finish() async {
            finishCount += 1
            let continuation = lock.withLock { () -> AsyncThrowingStream<RecognizedPhrase, Error>.Continuation? in
                defer { self.continuation = nil }
                return self.continuation
            }
            continuation?.finish()
        }

        func emit(_ phrase: RecognizedPhrase) {
            lock.withLock { continuation }?.yield(phrase)
        }

        func fail(_ error: Error) {
            let continuation = lock.withLock { () -> AsyncThrowingStream<RecognizedPhrase, Error>.Continuation? in
                defer { self.continuation = nil }
                return self.continuation
            }
            continuation?.finish(throwing: error)
        }
    }

    private struct Fixture {
        let capture: MicrophoneTapHubTests.FakeCapture
        let hub: MicrophoneTapHub
        let engine: FakeEngine
        let source: SpeechAnalyzerPartialSource
    }

    private func makeFixture(authorized: Bool = true) -> Fixture {
        let capture = MicrophoneTapHubTests.FakeCapture()
        let hub = MicrophoneTapHub(capture: capture, authorization: { authorized }, requestedDeviceName: { "" })
        let engine = FakeEngine()
        return Fixture(capture: capture, hub: hub, engine: engine, source: SpeechAnalyzerPartialSource(hub: hub, engine: engine))
    }

    private func makeBuffer(frames: Int = 480) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        return buffer
    }

    private func collect(_ stream: AsyncStream<PartialTranscript>, count: Int, timeout: Duration = .seconds(2)) async -> [PartialTranscript] {
        await withTaskGroup(of: [PartialTranscript].self) { group in
            group.addTask {
                var received: [PartialTranscript] = []
                for await transcript in stream {
                    received.append(transcript)
                    if received.count >= count { break }
                }
                return received
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return []
            }
            let first = await group.next() ?? []
            group.cancelAll()
            return first
        }
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testStartAttachesMicrophoneAfterRecogniserIsReadyAndStopReleasesBoth() async throws {
        let fixture = makeFixture()
        let stream = try await fixture.source.start(sessionID: "s1")
        XCTAssertEqual(fixture.engine.startCount, 1)
        XCTAssertEqual(fixture.hub.subscriberCount, 1)
        XCTAssertTrue(fixture.hub.isRunning)
        XCTAssertEqual(fixture.source.activeSessionID, "s1")

        fixture.capture.emit(try makeBuffer(frames: 480))
        fixture.capture.emit(try makeBuffer(frames: 480))
        XCTAssertEqual(fixture.engine.frames, 960, "Tap buffers reach the recogniser.")

        fixture.source.stop()
        XCTAssertNil(fixture.source.activeSessionID)
        XCTAssertEqual(fixture.hub.subscriberCount, 0)
        XCTAssertFalse(fixture.hub.isRunning)
        await waitUntil { fixture.engine.finishCount == 1 }
        XCTAssertEqual(fixture.engine.finishCount, 1)

        let remaining = await collect(stream, count: 1, timeout: .milliseconds(200))
        XCTAssertTrue(remaining.isEmpty, "The transcript stream ends when the session stops.")
    }

    func testPhrasesAreAssembledIntoTranscriptsInOrder() async throws {
        let fixture = makeFixture()
        let stream = try await fixture.source.start(sessionID: "s1")
        fixture.engine.emit(RecognizedPhrase(text: "Open", isFinal: false, start: 0, end: 1))
        fixture.engine.emit(RecognizedPhrase(text: "Open the Notes", isFinal: false, start: 0, end: 1))
        fixture.engine.emit(RecognizedPhrase(text: "Open the Notes app.", isFinal: true, start: 0, end: 1.8))
        let transcripts = await collect(stream, count: 3)
        XCTAssertEqual(transcripts.map(\.text), ["Open", "Open the Notes", "Open the Notes app."])
        XCTAssertEqual(transcripts.map(\.isFinal), [false, false, true])
        XCTAssertEqual(transcripts.map(\.sequence), [1, 2, 3])
        fixture.source.stop()
    }

    func testRecogniserEndingOnItsOwnReleasesTheMicrophone() async throws {
        let fixture = makeFixture()
        let stream = try await fixture.source.start(sessionID: "s1")
        fixture.engine.emit(RecognizedPhrase(text: "Hi", isFinal: false, start: 0, end: 0.5))
        fixture.engine.fail(SpeechAnalyzerEngineError.noCompatibleAudioFormat)
        let transcripts = await collect(stream, count: 2, timeout: .milliseconds(500))
        XCTAssertEqual(transcripts.map(\.text), ["Hi"], "The stream ends after the recogniser fails.")
        await waitUntil { fixture.source.activeSessionID == nil }
        XCTAssertNil(fixture.source.activeSessionID)
        XCTAssertEqual(fixture.hub.subscriberCount, 0)
        await waitUntil { fixture.engine.finishCount == 1 }
        XCTAssertEqual(fixture.engine.finishCount, 1)
    }

    func testStartingANewSessionStopsThePreviousOne() async throws {
        let fixture = makeFixture()
        let first = try await fixture.source.start(sessionID: "s1")
        let second = try await fixture.source.start(sessionID: "s2")
        XCTAssertEqual(fixture.source.activeSessionID, "s2")
        XCTAssertEqual(fixture.engine.startCount, 2)
        XCTAssertGreaterThanOrEqual(fixture.engine.finishCount, 1, "The first session is finished before the second starts.")
        XCTAssertEqual(fixture.hub.subscriberCount, 1, "Only the current session holds a microphone subscription.")

        fixture.engine.emit(RecognizedPhrase(text: "second", isFinal: false, start: 0, end: 0.5))
        let firstTranscripts = await collect(first, count: 1, timeout: .milliseconds(200))
        XCTAssertTrue(firstTranscripts.isEmpty, "A superseded session's stream receives nothing further.")
        let secondTranscripts = await collect(second, count: 1)
        XCTAssertEqual(secondTranscripts.map(\.text), ["second"])
        fixture.source.stop()
    }

    func testStopWithoutASessionIsANoOp() {
        let fixture = makeFixture()
        fixture.source.stop()
        fixture.source.stop()
        XCTAssertEqual(fixture.engine.finishCount, 0)
        XCTAssertEqual(fixture.hub.subscriberCount, 0)
    }

    func testRecogniserStartFailureLeavesMicrophoneUntouched() async {
        let fixture = makeFixture()
        fixture.engine.startFailure = SpeechAnalyzerEngineError.notAvailable(.unsupportedLocale("xx-XX"))
        do {
            _ = try await fixture.source.start(sessionID: "s1")
            XCTFail("Expected recogniser failure")
        } catch {
            XCTAssertEqual(error as? SpeechAnalyzerEngineError, .notAvailable(.unsupportedLocale("xx-XX")))
        }
        XCTAssertEqual(fixture.hub.subscriberCount, 0)
        XCTAssertEqual(fixture.capture.startCount, 0)
        XCTAssertNil(fixture.source.activeSessionID)
    }

    func testMicrophoneFailureFinishesTheRecogniser() async {
        let fixture = makeFixture(authorized: false)
        do {
            _ = try await fixture.source.start(sessionID: "s1")
            XCTFail("Expected microphone failure")
        } catch {
            XCTAssertEqual(error as? MicrophoneTapError, .microphoneAccessDenied)
        }
        XCTAssertEqual(fixture.engine.startCount, 1)
        XCTAssertEqual(fixture.engine.finishCount, 1, "A recogniser session must not be left open without audio.")
        XCTAssertNil(fixture.source.activeSessionID)
    }

    func testAvailabilityInstallAndPrewarmDelegateToTheEngine() async throws {
        let fixture = makeFixture()
        fixture.engine.availabilityResult = .assetsNotInstalled
        let availability = await fixture.source.availability()
        XCTAssertEqual(availability, .assetsNotInstalled)
        try await fixture.source.installAssets()
        XCTAssertEqual(fixture.engine.installCount, 1)
        let afterInstall = await fixture.source.availability()
        XCTAssertEqual(afterInstall, .available)
        await fixture.source.prewarm()
        XCTAssertEqual(fixture.engine.prewarmCount, 1)
    }

    func testCancellationAfterRecogniserStartsFinishesIt() async {
        let fixture = makeFixture()
        let task = Task { @MainActor in try await fixture.source.start(sessionID: "s1") }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        await waitUntil { fixture.engine.finishCount == fixture.engine.startCount }
        XCTAssertEqual(fixture.engine.finishCount, fixture.engine.startCount, "A started recogniser session must not be leaked.")
        XCTAssertEqual(fixture.hub.subscriberCount, 0)
        XCTAssertNil(fixture.source.activeSessionID)
    }
}
