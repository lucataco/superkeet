import XCTest
@testable import Superkeet

@MainActor
final class DemoActionsLiveTests: XCTestCase {
    final class FakeLauncher: NativeAppLaunching {
        private(set) var launched: [URL] = []
        func launch(applicationAt url: URL, awaitWindow: Bool) async throws -> NativeLaunchedApp {
            launched.append(url)
            return NativeLaunchedApp(
                name: url.deletingPathExtension().lastPathComponent,
                bundleIdentifier: "com.fixture.app",
                processIdentifier: 4_242,
                windowReady: true
            )
        }
    }

    final class FakeExecutor: NativeActionExecuting {
        private(set) var actions: [NativeOpenAction] = []
        func execute(_ action: NativeOpenAction) async throws -> String {
            actions.append(action)
            return "ok"
        }
    }

    func testDemoWavWritesAuditRowsOnOneTake() async throws {
        guard ProcessInfo.processInfo.environment["SUPERKEET_DAEMON_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set SUPERKEET_DAEMON_LIVE_TESTS=1 to play the demo WAV into the real speech engine.")
        }

        let wav = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/demo-actions/demo-audio.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path), wav.path)

        let settings = AppSettings.shared
        let saved = (
            settings.actionsEnabled,
            settings.instantAppLaunchEnabled,
            settings.actionAuditEnabled,
            settings.actionListeningSessionEnabled
        )
        settings.actionsEnabled = true
        settings.instantAppLaunchEnabled = true
        settings.actionAuditEnabled = true
        settings.actionListeningSessionEnabled = false

        let directory = URL(fileURLWithPath: "/fixture/Applications")
        let apps = ["Notes", "Arc", "Photo Booth"].map { directory.appendingPathComponent("\($0).app") }
        let inventory = InstalledAppInventory(
            makeResolver: { AppResolver(directories: [directory], applicationsInDirectory: { _ in apps }) },
            bundleLookup: { _ in nil },
            runningBundleURLs: { apps }
        )
        _ = await inventory.waitUntilReady(timeout: .seconds(5))

        let auditFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        let audit = ActionAuditStore(fileURL: auditFile)
        let launcher = FakeLauncher()
        let executor = FakeExecutor()
        let service = ParakeetService.shared
        let coordinator = SpeculativeLaunchCoordinator(
            settings: settings,
            source: DaemonPartialSource(engine: service),
            inventory: inventory,
            launcher: launcher,
            executor: executor,
            audit: audit
        )
        service.speculativeLaunchingOverride = coordinator
        defer {
            service.speculativeLaunchingOverride = nil
            settings.actionsEnabled = saved.0
            settings.instantAppLaunchEnabled = saved.1
            settings.actionAuditEnabled = saved.2
            settings.actionListeningSessionEnabled = saved.3
            try? FileManager.default.removeItem(at: auditFile)
        }

        try await service.startDaemon()
        defer { Task { await service.stopDaemonAndWait() } }
        XCTAssertEqual(service.daemonProtocolVersion, 2)

        service.armCommandMode()
        let started = await service.startRecording()
        XCTAssertTrue(started)

        let play = Process()
        play.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        play.arguments = [wav.path]
        try play.run()
        play.waitUntilExit()
        try await Task.sleep(for: .seconds(1))
        service.stopRecording()

        let deadline = Date().addingTimeInterval(30)
        while service.daemonState != .idle, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        let rows = audit.entries()
        print("LIVE transcript:", service.lastTranscription)
        print("LIVE audit:", rows.map { "\($0.sinceCommandMs ?? -1) \($0.toolName) \($0.outcome) \($0.arguments)" })
        XCTAssertEqual(service.daemonState, .idle)
        XCTAssertFalse(service.lastTranscription.isEmpty)
        XCTAssertTrue(
            service.lastTranscription.localizedCaseInsensitiveContains("note")
                || service.lastTranscription.localizedCaseInsensitiveContains("picture"),
            service.lastTranscription
        )
        XCTAssertFalse(rows.isEmpty, "A real coordinator must write audit rows for the demo WAV.")
    }
}
