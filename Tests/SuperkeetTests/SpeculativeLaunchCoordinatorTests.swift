import XCTest
@testable import Superkeet

@MainActor
final class SpeculativeLaunchCoordinatorTests: XCTestCase {
    final class FakeSource: PartialTranscriptSource {
        private(set) var startedSessions: [String] = []
        private(set) var stopCount = 0
        private(set) var prewarmCount = 0
        var availabilityResult = PartialTranscriptAvailability.available
        var startFailure: Error?
        private var continuation: AsyncStream<PartialTranscript>.Continuation?

        var isListening: Bool { continuation != nil }

        var displayName: String { "the fake recogniser" }

        func availability() async -> PartialTranscriptAvailability { availabilityResult }
        func installAssets() async throws { availabilityResult = .available }
        func prewarm() async { prewarmCount += 1 }

        func start(sessionID: String) async throws -> AsyncStream<PartialTranscript> {
            startedSessions.append(sessionID)
            if let startFailure { throw startFailure }
            let (stream, continuation) = AsyncStream.makeStream(of: PartialTranscript.self)
            self.continuation = continuation
            return stream
        }

        func stop() {
            stopCount += 1
            continuation?.finish()
            continuation = nil
        }

        func emit(_ text: String, sequence: Int, isFinal: Bool = false) {
            continuation?.yield(PartialTranscript(text: text, isFinal: isFinal, sequence: sequence))
        }
    }

    final class FakeLauncher: NativeAppLaunching {
        private(set) var launched: [URL] = []
        var failure: Error?
        var delay: Duration = .zero

        func launch(applicationAt url: URL) async throws -> NativeLaunchedApp {
            launched.append(url)
            if delay > .zero { try await Task.sleep(for: delay) }
            if let failure { throw failure }
            return NativeLaunchedApp(name: url.deletingPathExtension().lastPathComponent, bundleIdentifier: "com.fixture.app",
                                     processIdentifier: 4_242, windowReady: true)
        }
    }

    private struct Fixture {
        let source: FakeSource
        let launcher: FakeLauncher
        let inventory: InstalledAppInventory
        let audit: ActionAuditStore
        let auditFile: URL
        let coordinator: SpeculativeLaunchCoordinator
        let notes: URL
        let discord: URL
    }

    private nonisolated(unsafe) var savedSettings: (actions: Bool, instant: Bool, audit: Bool)?

    override func setUp() {
        super.setUp()
        let settings = AppSettings.shared
        savedSettings = (settings.actionsEnabled, settings.instantAppLaunchEnabled, settings.actionAuditEnabled)
        settings.actionsEnabled = true
        settings.instantAppLaunchEnabled = true
        settings.actionAuditEnabled = true
    }

    override func tearDown() {
        if let saved = savedSettings {
            AppSettings.shared.actionsEnabled = saved.actions
            AppSettings.shared.instantAppLaunchEnabled = saved.instant
            AppSettings.shared.actionAuditEnabled = saved.audit
        }
        super.tearDown()
    }

    private func makeFixture(source: FakeSource? = FakeSource(), running: [String] = []) async -> Fixture {
        let directory = URL(fileURLWithPath: "/fixture/Applications")
        let apps = ["Notes", "Discord", "Safari"].map { directory.appendingPathComponent("\($0).app") }
        let runningURLs = running.map { directory.appendingPathComponent("\($0).app") }
        let inventory = InstalledAppInventory(
            makeResolver: { AppResolver(directories: [directory], applicationsInDirectory: { _ in apps }) },
            bundleLookup: { _ in nil },
            runningBundleURLs: { runningURLs }
        )
        _ = await inventory.waitUntilReady(timeout: .seconds(5))
        let auditFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        let audit = ActionAuditStore(fileURL: auditFile)
        let launcher = FakeLauncher()
        let coordinator = SpeculativeLaunchCoordinator(
            settings: .shared, source: source, inventory: inventory, launcher: launcher, audit: audit, stabilityThreshold: 2
        )
        return Fixture(source: source ?? FakeSource(), launcher: launcher, inventory: inventory, audit: audit, auditFile: auditFile,
                       coordinator: coordinator, notes: apps[0], discord: apps[1])
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// Speaks the recorded recogniser output for the target command.
    private func speakNotesCommand(_ source: FakeSource) {
        source.emit("Open", sequence: 1)
        source.emit("Open the", sequence: 2)
        source.emit("Open the Notes", sequence: 3)
        source.emit("Open the Notes app", sequence: 4)
        source.emit("Open the Notes app and create a new note", sequence: 5)
    }

    // MARK: Happy path

    func testStableAppNameLaunchesBeforeTheTranscriptIsFinal() async throws {
        let fixture = await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.auditFile) }
        fixture.coordinator.begin(sessionID: "s1")
        await waitUntil { fixture.source.isListening }
        XCTAssertEqual(fixture.source.startedSessions, ["s1"])
        XCTAssertEqual(fixture.coordinator.activeSessionID, "s1")

        speakNotesCommand(fixture.source)
        await waitUntil { fixture.launcher.launched.count == 1 }
        XCTAssertEqual(fixture.launcher.launched, [fixture.notes])
        await waitUntil { fixture.coordinator.activity?.appName == "Notes" && fixture.coordinator.activity != .launching("Notes") }
        guard case .launched(let launched)? = fixture.coordinator.activity else {
            return XCTFail("Expected a launched activity, got \(String(describing: fixture.coordinator.activity))")
        }
        XCTAssertEqual(launched.processIdentifier, 4_242)

        let launch = try XCTUnwrap(fixture.coordinator.take(sessionID: "s1"))
        XCTAssertEqual(launch.commit.action, .launch(SpeculativeApp(spokenName: "notes", url: fixture.notes)))
        XCTAssertEqual(launch.commit.reason, .stable(count: 2))
        XCTAssertFalse(launch.disagreement)
        XCTAssertEqual(fixture.source.stopCount, 1, "Taking the launch stops listening.")
        XCTAssertNil(fixture.coordinator.activity, "The command's own HUD takes over after the transcript arrives.")
        XCTAssertNil(fixture.coordinator.activeSessionID)

        let result = await launch.result()
        XCTAssertEqual(result.launched?.name, "Notes")
        XCTAssertNil(result.failure)

        let entries = fixture.audit.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.toolName, "open_app")
        XCTAssertEqual(entries.first?.serverName, "superkeet")
        XCTAssertEqual(entries.first?.outcome, "speculative")
        XCTAssertEqual(entries.first?.risk, "mutating")
        XCTAssertTrue(entries.first?.arguments.contains("Notes") == true)
        XCTAssertTrue(entries.first?.detail?.contains("stable across 2 partials") == true, entries.first?.detail ?? "")
        XCTAssertTrue(entries.first?.detail?.contains("partial #4") == true)
    }

    func testTakeWaitsForALaunchStillInFlight() async throws {
        let fixture = await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.auditFile) }
        fixture.launcher.delay = .milliseconds(150)
        fixture.coordinator.begin(sessionID: "s1")
        await waitUntil { fixture.source.isListening }
        fixture.source.emit("Open Notes and", sequence: 1)
        await waitUntil { fixture.launcher.launched.count == 1 }
        XCTAssertEqual(fixture.coordinator.activity, .launching("Notes"))

        let launch = try XCTUnwrap(fixture.coordinator.take(sessionID: "s1"))
        XCTAssertEqual(launch.commit.reason, .clauseBoundary)
        let result = await launch.result()
        XCTAssertEqual(result.launched?.name, "Notes", "The result resolves once macOS reports the launch.")
        XCTAssertNil(fixture.coordinator.activity, "Activity is not revived for a session that was already handed over.")
    }

    func testActivationRequiresARunningApp() async throws {
        let fixture = await makeFixture(running: ["Discord"])
        defer { try? FileManager.default.removeItem(at: fixture.auditFile) }
        fixture.coordinator.begin(sessionID: "s1")
        await waitUntil { fixture.source.isListening }
        fixture.source.emit("Switch to Discord and", sequence: 1)
        await waitUntil { fixture.launcher.launched.count == 1 }
        XCTAssertEqual(fixture.launcher.launched, [fixture.discord])
        let launch = try XCTUnwrap(fixture.coordinator.take(sessionID: "s1"))
        XCTAssertTrue(launch.commit.action.isActivation)
        XCTAssertTrue(fixture.audit.entries().first?.detail?.contains("activated") == true)
    }

    // MARK: Nothing to do

    func testTakeWithoutACommitReturnsNothingAndStopsListening() async {
        let fixture = await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.auditFile) }
        fixture.coordinator.begin(sessionID: "s1")
        await waitUntil { fixture.source.isListening }
        fixture.source.emit("Create a new note", sequence: 1)
        fixture.source.emit("Create a new note in Notes", sequence: 2, isFinal: true)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(fixture.coordinator.take(sessionID: "s1"))
        XCTAssertEqual(fixture.source.stopCount, 1)
        XCTAssertTrue(fixture.launcher.launched.isEmpty)
        XCTAssertTrue(fixture.audit.entries().isEmpty)
    }

    func testMisheardNameNeverLaunches() async {
        let fixture = await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.auditFile) }
        fixture.coordinator.begin(sessionID: "s1")
        await waitUntil { fixture.source.isListening }
        fixture.source.emit("Open Nodes", sequence: 1)
        fixture.source.emit("Open Nodes and", sequence: 2)
        fixture.source.emit("Open Nodes and create", sequence: 3, isFinal: true)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(fixture.launcher.launched.isEmpty)
        XCTAssertNil(fixture.coordinator.take(sessionID: "s1"))
    }

    // MARK: Gating

    func testDisabledSettingsSkipListeningEntirely() async {
        for disable in [\AppSettings.actionsEnabled, \AppSettings.instantAppLaunchEnabled] {
            let fixture = await makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.auditFile) }
            AppSettings.shared[keyPath: disable] = false
            XCTAssertFalse(fixture.coordinator.isEnabled)
            fixture.coordinator.begin(sessionID: "s1")
            try? await Task.sleep(for: .milliseconds(20))
            XCTAssertTrue(fixture.source.startedSessions.isEmpty)
            XCTAssertNil(fixture.coordinator.activeSessionID)
            XCTAssertNil(fixture.coordinator.take(sessionID: "s1"))
            AppSettings.shared[keyPath: disable] = true
        }
    }

    func testUnsupportedSystemHasNoSource() async {
        let fixture = await makeFixture(source: nil)
        defer { try? FileManager.default.removeItem(at: fixture.auditFile) }
        XCTAssertFalse(fixture.coordinator.isSupported)
        XCTAssertFalse(fixture.coordinator.isEnabled)
        let availability = await fixture.coordinator.availability()
        XCTAssertEqual(availability, .requiresNewerOS)
        fixture.coordinator.begin(sessionID: "s1")
        XCTAssertNil(fixture.coordinator.activeSessionID)
        do {
            try await fixture.coordinator.installAssets()
            XCTFail("Expected an unavailable error")
        } catch {
            XCTAssertEqual(error as? SpeechAnalyzerEngineError, .notAvailable(.requiresNewerOS))
        }
    }

    func testRecogniserStartFailureLeavesNoSession() async {
        let fixture = await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.auditFile) }
        fixture.source.startFailure = SpeechAnalyzerEngineError.notAvailable(.assetsNotInstalled)
        fixture.coordinator.begin(sessionID: "s1")
        await waitUntil { fixture.source.startedSessions.count == 1 }
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(fixture.coordinator.take(sessionID: "s1"), "No commit is possible without recognition.")
        XCTAssertTrue(fixture.launcher.launched.isEmpty)
    }

    // MARK: Session lifecycle

    func testEndStopsListeningButLetsAnInFlightLaunchFinishAndBeAudited() async {
        let fixture = await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.auditFile) }
        fixture.launcher.delay = .milliseconds(100)
        fixture.coordinator.begin(sessionID: "s1")
        await waitUntil { fixture.source.isListening }
        fixture.source.emit("Open Notes and", sequence: 1)
        await waitUntil { fixture.launcher.launched.count == 1 }

        fixture.coordinator.end(sessionID: "s1")
        XCTAssertEqual(fixture.source.stopCount, 1)
        XCTAssertNil(fixture.coordinator.activity)
        XCTAssertNil(fixture.coordinator.activeSessionID)
        XCTAssertNil(fixture.coordinator.take(sessionID: "s1"), "An ended session hands nothing over.")

        await waitUntil { !fixture.audit.entries().isEmpty }
        XCTAssertEqual(fixture.audit.entries().map(\.outcome), ["speculative"], "The open request already reached macOS.")
        XCTAssertNil(fixture.coordinator.activity, "A finished launch does not revive the HUD after the session ended.")
    }

    func testSessionIdentifiersAreRespected() async {
        let fixture = await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.auditFile) }
        fixture.coordinator.begin(sessionID: "s1")
        await waitUntil { fixture.source.isListening }
        fixture.coordinator.end(sessionID: "other")
        XCTAssertEqual(fixture.coordinator.activeSessionID, "s1")
        XCTAssertNil(fixture.coordinator.take(sessionID: "other"))
        XCTAssertEqual(fixture.source.stopCount, 0)

        fixture.coordinator.begin(sessionID: "s2")
        await waitUntil { fixture.source.startedSessions.count == 2 }
        XCTAssertEqual(fixture.coordinator.activeSessionID, "s2")
        XCTAssertEqual(fixture.source.stopCount, 1, "Starting a new session stops the previous one.")
        fixture.coordinator.end(sessionID: "s2")
    }

    func testPartialsAfterTakeAreIgnored() async throws {
        let fixture = await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.auditFile) }
        fixture.coordinator.begin(sessionID: "s1")
        await waitUntil { fixture.source.isListening }
        XCTAssertNil(fixture.coordinator.take(sessionID: "s1"))
        fixture.source.emit("Open Notes and", sequence: 1)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(fixture.launcher.launched.isEmpty)
    }

    // MARK: Failures

    func testLaunchFailureIsReportedAndAudited() async throws {
        let fixture = await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.auditFile) }
        fixture.launcher.failure = NativeOpenActionError.openFailed("Launch refused")
        fixture.coordinator.begin(sessionID: "s1")
        await waitUntil { fixture.source.isListening }
        fixture.source.emit("Open Notes and", sequence: 1)
        await waitUntil { fixture.coordinator.activity != nil && fixture.coordinator.activity != .launching("Notes") }
        guard case .failed(let name, let message)? = fixture.coordinator.activity else {
            return XCTFail("Expected a failed activity, got \(String(describing: fixture.coordinator.activity))")
        }
        XCTAssertEqual(name, "Notes")
        XCTAssertTrue(message.contains("Launch refused"))

        let launch = try XCTUnwrap(fixture.coordinator.take(sessionID: "s1"))
        let result = await launch.result()
        XCTAssertNil(result.launched)
        XCTAssertTrue(result.failure?.contains("Launch refused") == true)
        XCTAssertEqual(result.appName, "Notes")
        XCTAssertEqual(fixture.audit.entries().map(\.outcome), ["failed"])
    }

    func testAuditCanBeDisabled() async {
        let fixture = await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.auditFile) }
        AppSettings.shared.actionAuditEnabled = false
        fixture.coordinator.begin(sessionID: "s1")
        await waitUntil { fixture.source.isListening }
        fixture.source.emit("Open Notes and", sequence: 1)
        await waitUntil { fixture.launcher.launched.count == 1 }
        _ = fixture.coordinator.take(sessionID: "s1")
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(fixture.audit.entries().isEmpty)
    }

    // MARK: Interim text demand

    func testEngineIsAskedForInterimTextOnlyWhenTheFeatureCanUseIt() async {
        let fixture = await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.auditFile) }
        XCTAssertTrue(fixture.coordinator.wantsInterimTranscripts())
        AppSettings.shared.instantAppLaunchEnabled = false
        XCTAssertFalse(fixture.coordinator.wantsInterimTranscripts(), "Disabled: the engine should not spend cycles on previews.")
        AppSettings.shared.instantAppLaunchEnabled = true
        AppSettings.shared.actionsEnabled = false
        XCTAssertFalse(fixture.coordinator.wantsInterimTranscripts())
        AppSettings.shared.actionsEnabled = true

        let unsupported = await makeFixture(source: nil)
        defer { try? FileManager.default.removeItem(at: unsupported.auditFile) }
        XCTAssertFalse(unsupported.coordinator.wantsInterimTranscripts())
    }

    func testRecognizerNameReflectsTheSourceThatWouldRun() async {
        let fixture = await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.auditFile) }
        let name = await fixture.coordinator.recognizerName()
        XCTAssertEqual(name, "the fake recogniser")
        fixture.source.availabilityResult = .assetsNotInstalled
        let missing = await fixture.coordinator.recognizerName()
        XCTAssertNil(missing)
    }

    // MARK: Preparation

    func testPrepareChecksAvailabilityAndPrewarmsOnce() async {
        let fixture = await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.auditFile) }
        await fixture.coordinator.prepare()
        await fixture.coordinator.prepare()
        XCTAssertEqual(fixture.source.prewarmCount, 1)

        let cold = await makeFixture()
        defer { try? FileManager.default.removeItem(at: cold.auditFile) }
        cold.source.availabilityResult = .assetsNotInstalled
        await cold.coordinator.prepare()
        XCTAssertEqual(cold.source.prewarmCount, 0, "Nothing is loaded while the model is missing.")
        try? await cold.coordinator.installAssets()
        XCTAssertEqual(cold.source.prewarmCount, 1, "Installing the model completes preparation.")
    }
}
