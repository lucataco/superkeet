import XCTest
@testable import Superkeet

@MainActor
final class DaemonInterimLiveTests: XCTestCase {
    final class RecordingLaunching: SpeculativeLaunching {
        var begun: [String] = []
        var ended: [String] = []
        var taken: [String] = []
        func wantsInterimTranscripts() -> Bool { true }
        func begin(sessionID: String) { begun.append(sessionID) }
        func end(sessionID: String) { ended.append(sessionID) }
        func take(sessionID: String) -> SpeculativeLaunch? { taken.append(sessionID); return nil }
    }

    func testDaemonStreamsPartialsForACommandModeRecording() async throws {
        guard ProcessInfo.processInfo.environment["SUPERKEET_DAEMON_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set SUPERKEET_DAEMON_LIVE_TESTS=1 to run against the real speech engine with audible playback.")
        }
        let service = ParakeetService.shared
        let settings = AppSettings.shared
        let savedActions = settings.actionsEnabled
        let savedInstant = settings.instantAppLaunchEnabled
        settings.actionsEnabled = true
        settings.instantAppLaunchEnabled = true
        let launching = RecordingLaunching()
        service.speculativeLaunchingOverride = launching
        defer {
            service.speculativeLaunchingOverride = nil
            settings.actionsEnabled = savedActions
            settings.instantAppLaunchEnabled = savedInstant
        }

        try await service.startDaemon()
        defer { Task { await service.stopDaemonAndWait() } }
        XCTAssertEqual(service.daemonProtocolVersion, 2, "The development engine checkout should speak protocol 2.")

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("superkeet-live-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: file) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", file.path, "open the notes app and create a new note"]
        try say.run()
        say.waitUntilExit()

        service.armCommandMode()
        let started = await service.startRecording()
        XCTAssertTrue(started)
        let sessionID = try XCTUnwrap(launching.begun.first, "Command Mode recording must notify the coordinator.")
        let partials = service.interimTranscripts(sessionID: sessionID)
        let collector = Task { () -> [PartialTranscript] in
            var seen: [PartialTranscript] = []
            for await transcript in partials { seen.append(transcript) }
            return seen
        }

        let play = Process()
        play.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        play.arguments = [file.path]
        try play.run()
        play.waitUntilExit()
        try await Task.sleep(for: .seconds(1))
        service.stopRecording()

        let deadline = Date().addingTimeInterval(20)
        while service.daemonState != .idle, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        let seen = await collector.value
        print("LIVE partials:", seen.map { "#\($0.sequence) \($0.text)" }, "final:", service.lastTranscription)

        XCTAssertEqual(service.daemonState, .idle, "The session must complete.")
        XCTAssertEqual(launching.taken, [sessionID], "The final transcript hands the session to the coordinator.")
        XCTAssertFalse(seen.isEmpty, "Expected at least one interim transcript from the engine while recording.")
        XCTAssertEqual(seen.map(\.sequence), Array(1...seen.count), "Sequences are contiguous from one.")
        XCTAssertTrue(seen.allSatisfy { !$0.isFinal && !$0.text.isEmpty })
        XCTAssertTrue(seen.contains { $0.text.localizedCaseInsensitiveContains("note") },
                      "The app name should be heard in interim text before the recording stops.")
        XCTAssertTrue(service.lastTranscription.localizedCaseInsensitiveContains("note"),
                      "The engine's final transcript still arrives as usual.")
    }
}
