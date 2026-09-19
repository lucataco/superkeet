import AVFoundation
import XCTest
@testable import Superkeet

@MainActor
final class SpeculativeLaunchIntegrationTests: XCTestCase {
    private nonisolated(unsafe) var savedSettings: (actions: Bool, instant: Bool, audit: Bool)?

    override func setUp() {
        super.setUp()
        let settings = AppSettings.shared
        savedSettings = (settings.actionsEnabled, settings.instantAppLaunchEnabled, settings.actionAuditEnabled)
        settings.actionsEnabled = true
        settings.instantAppLaunchEnabled = true
        settings.actionAuditEnabled = false
    }

    override func tearDown() {
        if let saved = savedSettings {
            AppSettings.shared.actionsEnabled = saved.actions
            AppSettings.shared.instantAppLaunchEnabled = saved.instant
            AppSettings.shared.actionAuditEnabled = saved.audit
        }
        super.tearDown()
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    func testSpokenCommandLaunchesNotesBeforeTheSentenceEnds() async throws {
        let engine = SpeechAnalyzerEngine(configuration: .init(locale: Locale(identifier: "en-US"), contextualStrings: { ["Notes"] }))
        let availability = await engine.availability()
        guard availability == .available else { throw XCTSkip("On-device speech model unavailable: \(availability)") }

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

        let capture = MicrophoneTapHubTests.FakeCapture()
        let hub = MicrophoneTapHub(capture: capture, authorization: { true }, requestedDeviceName: { "" })
        let source = SpeechAnalyzerPartialSource(hub: hub, engine: engine)
        let inventory = InstalledAppInventory()
        guard await inventory.waitUntilReady(timeout: .seconds(15)) else { throw XCTSkip("Installed-app scan did not finish") }
        guard let notes = inventory.resolve("Notes") else { throw XCTSkip("Notes is not installed") }
        let launcher = SpeculativeLaunchCoordinatorTests.FakeLauncher()
        let coordinator = SpeculativeLaunchCoordinator(
            settings: .shared, source: source, inventory: inventory, launcher: launcher,
            audit: ActionAuditStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        )

        coordinator.begin(sessionID: "s1")
        let deadline = Date().addingTimeInterval(5)
        while !hub.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(hub.isRunning, "The recogniser should be listening through the shared tap.")

        let started = ContinuousClock.now
        var launchedAt: Duration?
        let chunk = AVAudioFrameCount(audio.processingFormat.sampleRate / 10)
        while audio.framePosition < audio.length {
            let frames = min(chunk, AVAudioFrameCount(audio.length - audio.framePosition))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: frames))
            try audio.read(into: buffer, frameCount: frames)
            capture.emit(buffer)
            if launchedAt == nil, !launcher.launched.isEmpty { launchedAt = started.duration(to: .now) }
            try await Task.sleep(for: .milliseconds(100))
        }
        for _ in 0..<15 where launcher.launched.isEmpty {
            let silence = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: chunk))
            silence.frameLength = chunk
            capture.emit(silence)
            try await Task.sleep(for: .milliseconds(100))
        }
        if launchedAt == nil, !launcher.launched.isEmpty { launchedAt = started.duration(to: .now) }

        XCTAssertEqual(launcher.launched.map(\.standardizedFileURL.path), [notes.standardizedFileURL.path],
                       "Exactly one launch, of the installed Notes app.")
        let latency = try XCTUnwrap(launchedAt, "Notes was never launched from interim speech.")
        XCTAssertLessThan(latency, .seconds(utteranceSeconds + 1.0),
                          "The launch should fire while the sentence is still being spoken or right as it ends.")

        let launch = try XCTUnwrap(coordinator.take(sessionID: "s1"))
        XCTAssertEqual(launch.commit.action.app.url.standardizedFileURL.path, notes.standardizedFileURL.path)
        let result = await launch.result()
        XCTAssertEqual(result.launched?.name, "Notes")
        XCTAssertFalse(hub.isRunning, "Taking the launch releases the microphone.")
    }
    #endif
}
