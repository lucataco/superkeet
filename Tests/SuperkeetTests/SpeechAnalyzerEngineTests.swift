import AVFoundation
import XCTest
@testable import Superkeet

@MainActor
final class SpeechAnalyzerEngineTests: XCTestCase {
    func testFactoryPrefersTheEngineAndFallsBackToAppleSpeechWhereAvailable() async throws {
        let hub = MicrophoneTapHub(capture: MicrophoneTapHubTests.FakeCapture(), authorization: { true }, requestedDeviceName: { "" })
        let engine = DaemonPartialSourceTests.FakeEngine(protocolVersion: 2)
        let source = try XCTUnwrap(PartialTranscriptSources.make(hub: hub, engine: engine) as? PreferredPartialSource)
        let preferred = await source.preferredSource()
        XCTAssertEqual(preferred?.displayName, "the Parakeet engine", "A protocol-2 daemon always wins.")

        engine.daemonProtocolVersion = 1
        let withoutEngine = try XCTUnwrap(PartialTranscriptSources.make(hub: hub, engine: engine) as? PreferredPartialSource)
        let availability = await withoutEngine.availability()
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            // The fallback answers; whether it is ready depends on the speech model being installed.
            XCTAssertNotEqual(availability, .unavailable(DaemonPartialSource.unavailableReason(protocolVersion: 1)))
            return
        }
        #endif
        XCTAssertEqual(availability, .unavailable(DaemonPartialSource.unavailableReason(protocolVersion: 1)), "No fallback on older systems.")
    }

    #if canImport(FoundationModels)
    /// Feeds a synthesized command through the real engine at live cadence and
    /// checks that the app name shows up before the speech ends. Skips when the
    /// on-device model is not installed so CI runners never download assets.
    @available(macOS 26.0, *)
    func testRealEngineSpotsAppNameBeforeUtteranceEnds() async throws {
        let engine = SpeechAnalyzerEngine(configuration: .init(
            locale: Locale(identifier: "en-US"),
            contextualStrings: { ["Notes", "Discord"] }
        ))
        let availability = await engine.availability()
        guard availability == .available else {
            throw XCTSkip("On-device speech model unavailable: \(availability)")
        }

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("superkeet-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: file) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", file.path, "open the notes app and create a new note"]
        try say.run()
        say.waitUntilExit()
        guard say.terminationStatus == 0 else { throw XCTSkip("say is unavailable on this runner") }
        let audio = try AVAudioFile(forReading: file)
        let utteranceSeconds = Double(audio.length) / audio.processingFormat.sampleRate

        let phrases = try await engine.start()
        let started = ContinuousClock.now
        let firstNotes = Task { () -> Duration? in
            for try await phrase in phrases where phrase.text.localizedCaseInsensitiveContains("notes") {
                return started.duration(to: .now)
            }
            return nil
        }

        // Stream 100 ms chunks in real time, like the microphone tap would, then a little silence.
        let chunk = AVAudioFrameCount(audio.processingFormat.sampleRate / 10)
        while audio.framePosition < audio.length {
            let frames = min(chunk, AVAudioFrameCount(audio.length - audio.framePosition))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: frames))
            try audio.read(into: buffer, frameCount: frames)
            engine.append(buffer)
            try await Task.sleep(for: .milliseconds(100))
        }
        for _ in 0..<15 {
            let silence = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: chunk))
            silence.frameLength = chunk
            engine.append(silence)
            try await Task.sleep(for: .milliseconds(100))
        }
        await engine.finish()

        let latency = try await firstNotes.value
        XCTAssertNotNil(latency, "The recogniser never produced the app name.")
        if let latency {
            XCTAssertLessThan(latency, .seconds(utteranceSeconds + 1.5),
                              "The app name should be recognised while the sentence is still being spoken.")
        }
    }

    @available(macOS 26.0, *)
    func testConverterResamplesTapBuffersIntoAnalyzerFormat() throws {
        let input = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let output = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let converter = try XCTUnwrap(AVAudioConverter(from: input, to: output))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 4_800))
        buffer.frameLength = 4_800
        let converted = try XCTUnwrap(SpeechAnalyzerEngine.convert(buffer, using: converter, to: output))
        XCTAssertEqual(converted.format, output)
        XCTAssertGreaterThan(converted.frameLength, 1_000, "The resampler primes on the first buffer but still yields most of it.")

        // The resampler alternates between catching up (filling the output buffer) and
        // running at rate; what matters is that the deficit stays a fixed latency
        // rather than growing into a backlog.
        var total = Int(converted.frameLength)
        for _ in 0..<49 {
            let next = try XCTUnwrap(SpeechAnalyzerEngine.convert(buffer, using: converter, to: output))
            XCTAssertTrue((1_300...1_650).contains(Int(next.frameLength)), "Unexpected chunk size \(next.frameLength)")
            total += Int(next.frameLength)
        }
        XCTAssertEqual(total, 80_000, accuracy: 400, "Five seconds of input become five seconds of output within a fixed latency.")

        let empty = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 16))
        XCTAssertNil(SpeechAnalyzerEngine.convert(empty, using: converter, to: output))
    }
    #endif
}
