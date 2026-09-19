import XCTest
@testable import Superkeet

@MainActor
final class DaemonPartialSourceTests: XCTestCase {
    /// Stands in for `ParakeetService`: reports a protocol version and lets a
    /// test push interim transcripts into the stream a session opened.
    final class FakeEngine: InterimTranscriptProviding {
        var daemonProtocolVersion: Int?
        private(set) var opened: [String] = []
        private(set) var ended: [String] = []
        private var continuations: [String: AsyncStream<PartialTranscript>.Continuation] = [:]

        init(protocolVersion: Int?) { daemonProtocolVersion = protocolVersion }

        var daemonStreamsInterimText: Bool { daemonProtocolVersion == ParakeetService.interimTextProtocolVersion }

        func interimTranscripts(sessionID: String) -> AsyncStream<PartialTranscript> {
            opened.append(sessionID)
            let (stream, continuation) = AsyncStream.makeStream(of: PartialTranscript.self)
            continuations[sessionID] = continuation
            return stream
        }

        func endInterimTranscripts(sessionID: String) {
            ended.append(sessionID)
            continuations.removeValue(forKey: sessionID)?.finish()
        }

        func emit(_ text: String, sequence: Int, sessionID: String) {
            continuations[sessionID]?.yield(PartialTranscript(text: text, isFinal: false, sequence: sequence))
        }
    }

    /// A scripted fallback recogniser.
    final class FakeFallback: PartialTranscriptSource {
        var availabilityResult = PartialTranscriptAvailability.available
        private(set) var started: [String] = []
        private(set) var stopCount = 0
        private(set) var prewarmCount = 0
        private(set) var installCount = 0
        var displayName: String { "the fallback recogniser" }
        func availability() async -> PartialTranscriptAvailability { availabilityResult }
        func installAssets() async throws { installCount += 1 }
        func prewarm() async { prewarmCount += 1 }
        func start(sessionID: String) async throws -> AsyncStream<PartialTranscript> {
            started.append(sessionID)
            return AsyncStream { $0.finish() }
        }
        func stop() { stopCount += 1 }
    }

    private func collect(_ stream: AsyncStream<PartialTranscript>, count: Int) async -> [PartialTranscript] {
        var received: [PartialTranscript] = []
        for await transcript in stream {
            received.append(transcript)
            if received.count >= count { break }
        }
        return received
    }

    // MARK: Daemon source

    func testProtocolTwoEngineStreamsItsInterimText() async throws {
        let engine = FakeEngine(protocolVersion: 2)
        let source = DaemonPartialSource(engine: engine)
        let availability = await source.availability()
        XCTAssertEqual(availability, .available)
        XCTAssertEqual(source.displayName, "the Parakeet engine")

        let stream = try await source.start(sessionID: "s1")
        XCTAssertEqual(engine.opened, ["s1"])
        XCTAssertEqual(source.activeSessionID, "s1")
        engine.emit("Open the notes up", sequence: 1, sessionID: "s1")
        engine.emit("Open the notes app and create a", sequence: 2, sessionID: "s1")
        let received = await collect(stream, count: 2)
        XCTAssertEqual(received.map(\.text), ["Open the notes up", "Open the notes app and create a"])
        XCTAssertEqual(received.map(\.sequence), [1, 2])
        XCTAssertTrue(received.allSatisfy { !$0.isFinal }, "The engine's final text arrives as `complete`, never as a partial.")

        source.stop()
        XCTAssertEqual(engine.ended, ["s1"])
        XCTAssertNil(source.activeSessionID)
        source.stop()
        XCTAssertEqual(engine.ended, ["s1"], "Stopping twice ends the session once.")
    }

    func testProtocolOneEngineIsUnavailableAndRefusesToStart() async {
        for version in [Optional(1), nil] {
            let engine = FakeEngine(protocolVersion: version)
            let source = DaemonPartialSource(engine: engine)
            let availability = await source.availability()
            XCTAssertFalse(availability.isAvailable)
            let message = availability.userFacingMessage ?? ""
            XCTAssertTrue(message.contains(version == nil ? "not running yet" : "protocol 1"), message)
            do {
                _ = try await source.start(sessionID: "s1")
                XCTFail("Expected the source to refuse")
            } catch {
                XCTAssertTrue(error is SpeechAnalyzerEngineError)
            }
            XCTAssertTrue(engine.opened.isEmpty)
        }
    }

    func testStartingANewSessionEndsThePreviousOne() async throws {
        let engine = FakeEngine(protocolVersion: 2)
        let source = DaemonPartialSource(engine: engine)
        _ = try await source.start(sessionID: "s1")
        _ = try await source.start(sessionID: "s2")
        XCTAssertEqual(engine.opened, ["s1", "s2"])
        XCTAssertEqual(engine.ended, ["s1"])
        XCTAssertEqual(source.activeSessionID, "s2")
    }

    func testNothingToInstallOrPrewarm() async throws {
        let source = DaemonPartialSource(engine: FakeEngine(protocolVersion: 2))
        try await source.installAssets()
        await source.prewarm()
    }

    // MARK: Preferred source

    func testEngineIsPreferredWhenItStreamsInterimText() async throws {
        let engine = FakeEngine(protocolVersion: 2)
        let fallback = FakeFallback()
        let source = PreferredPartialSource(primary: DaemonPartialSource(engine: engine), fallback: fallback)
        let availability = await source.availability()
        XCTAssertEqual(availability, .available)
        let preferred = await source.preferredSource()
        XCTAssertEqual(preferred?.displayName, "the Parakeet engine")

        await source.prewarm()
        try await source.installAssets()
        XCTAssertEqual(fallback.prewarmCount, 0, "The fallback is not warmed while the engine will be used.")
        XCTAssertEqual(fallback.installCount, 0)

        _ = try await source.start(sessionID: "s1")
        XCTAssertEqual(engine.opened, ["s1"])
        XCTAssertTrue(fallback.started.isEmpty)
        XCTAssertEqual(source.displayName, "the Parakeet engine")
        source.stop()
        XCTAssertEqual(engine.ended, ["s1"])
        XCTAssertEqual(fallback.stopCount, 0)
    }

    func testFallbackIsUsedUntilTheEngineOffersInterimText() async throws {
        let engine = FakeEngine(protocolVersion: nil)
        let fallback = FakeFallback()
        let source = PreferredPartialSource(primary: DaemonPartialSource(engine: engine), fallback: fallback)
        let availability = await source.availability()
        XCTAssertEqual(availability, .available, "The fallback's availability stands in for the engine's.")
        let preferred = await source.preferredSource()
        XCTAssertEqual(preferred?.displayName, "the fallback recogniser")
        await source.prewarm()
        XCTAssertEqual(fallback.prewarmCount, 1)

        _ = try await source.start(sessionID: "s1")
        XCTAssertEqual(fallback.started, ["s1"])
        XCTAssertTrue(engine.opened.isEmpty)
        XCTAssertEqual(source.displayName, "the fallback recogniser")
        source.stop()
        XCTAssertEqual(fallback.stopCount, 1)

        // The daemon comes up speaking protocol 2: the very next session uses it.
        engine.daemonProtocolVersion = 2
        _ = try await source.start(sessionID: "s2")
        XCTAssertEqual(engine.opened, ["s2"])
        XCTAssertEqual(fallback.started, ["s1"])
        source.stop()
    }

    func testFallbackAvailabilityAndInstallFlowThroughWhenEngineCannot() async throws {
        let engine = FakeEngine(protocolVersion: 1)
        let fallback = FakeFallback()
        fallback.availabilityResult = .assetsNotInstalled
        let source = PreferredPartialSource(primary: DaemonPartialSource(engine: engine), fallback: fallback)
        let availability = await source.availability()
        XCTAssertEqual(availability, .assetsNotInstalled)
        try await source.installAssets()
        XCTAssertEqual(fallback.installCount, 1)
        let preferred = await source.preferredSource()
        XCTAssertNil(preferred, "Nothing is ready to produce interim text yet.")
    }

    func testWithoutAFallbackTheEngineErrorIsReported() async {
        let engine = FakeEngine(protocolVersion: 1)
        let source = PreferredPartialSource(primary: DaemonPartialSource(engine: engine), fallback: nil)
        let availability = await source.availability()
        XCTAssertFalse(availability.isAvailable)
        do {
            _ = try await source.start(sessionID: "s1")
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(error as? SpeechAnalyzerEngineError, .notAvailable(.unavailable(DaemonPartialSource.unavailableReason(protocolVersion: 1))))
        }
    }
}
