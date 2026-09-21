import Combine
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
        private(set) var awaitedWindows: [Bool] = []
        var failure: Error?
        var delay: Duration = .zero

        func launch(applicationAt url: URL, awaitWindow: Bool) async throws -> NativeLaunchedApp {
            launched.append(url)
            awaitedWindows.append(awaitWindow)
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

    private func speakNotesCommand(_ source: FakeSource) {
        source.emit("Open", sequence: 1)
        source.emit("Open the", sequence: 2)
        source.emit("Open the Notes", sequence: 3)
        source.emit("Open the Notes app", sequence: 4)
        source.emit("Open the Notes app and create a new note", sequence: 5)
    }

    func testListeningPublishesEachCumulativePartialAndClearsOnTake() async {
        let fixture = await makeFixture()
        defer { fixture.coordinator.end(sessionID: "s1"); try? FileManager.default.removeItem(at: fixture.auditFile) }
        var states: [SpeculativeLaunchCoordinator.Listening?] = []
        let subscription = fixture.coordinator.$listening.sink { states.append($0) }
        defer { subscription.cancel() }
        fixture.coordinator.begin(sessionID: "s1")
        XCTAssertEqual(fixture.coordinator.listening, .init(sessionID: "s1", transcript: ""))
        await waitUntil { fixture.source.isListening }

        let words = ["Create", "Create a new", "Create a new note"]
        for (index, text) in words.enumerated() {
            fixture.source.emit(text, sequence: index + 1, isFinal: index == words.count - 1)
            await waitUntil { fixture.coordinator.listening?.transcript == text }
            XCTAssertEqual(fixture.coordinator.listening, .init(sessionID: "s1", transcript: text))
        }
        XCTAssertNil(fixture.coordinator.take(sessionID: "s1"))
        XCTAssertNil(fixture.coordinator.listening)
        let expected: [SpeculativeLaunchCoordinator.Listening?] = [nil, .init(sessionID: "s1", transcript: "")]
            + words.map { .init(sessionID: "s1", transcript: $0) } + [nil]
        XCTAssertEqual(states, expected)
        XCTAssertTrue(fixture.launcher.launched.isEmpty)
    }

    func testListeningRemainsThroughTheTranscribingGapUntilEnd() async {
        let fixture = await makeFixture()
        defer { fixture.coordinator.end(sessionID: "s1"); try? FileManager.default.removeItem(at: fixture.auditFile) }
        fixture.coordinator.begin(sessionID: "s1")
        await waitUntil { fixture.source.isListening }
        fixture.source.emit("Create a new note", sequence: 1, isFinal: true)
        await waitUntil { fixture.coordinator.listening?.transcript == "Create a new note" }
        fixture.source.stop()
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(fixture.coordinator.listening, .init(sessionID: "s1", transcript: "Create a new note"))
        fixture.coordinator.end(sessionID: "s1")
        XCTAssertNil(fixture.coordinator.listening)
        XCTAssertNil(fixture.coordinator.activeSessionID)
    }

    func testListeningPublishesFromThePreferredEngineOrFallback() async {
        AppSettings.shared.instantAppLaunchEnabled = false
        for version in [2, 1] {
            let fixture = await makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.auditFile) }
            let engine = DaemonPartialSourceTests.FakeEngine(protocolVersion: version)
            let source = PreferredPartialSource(primary: DaemonPartialSource(engine: engine), fallback: fixture.source)
            let coordinator = SpeculativeLaunchCoordinator(source: source, inventory: fixture.inventory,
                                                          launcher: fixture.launcher, audit: fixture.audit)
            defer { coordinator.end(sessionID: "s1") }
            coordinator.begin(sessionID: "s1")
            if version == 2 {
                await waitUntil { engine.opened == ["s1"] }
                engine.emit("Open Notes", sequence: 1, sessionID: "s1")
                XCTAssertTrue(fixture.source.startedSessions.isEmpty)
            } else {
                await waitUntil { fixture.source.isListening }
                fixture.source.emit("Open Notes", sequence: 1)
                XCTAssertTrue(engine.opened.isEmpty)
            }
            await waitUntil { coordinator.listening?.transcript == "Open Notes" }
            XCTAssertEqual(coordinator.listening, .init(sessionID: "s1", transcript: "Open Notes"))
            XCTAssertNil(coordinator.take(sessionID: "s1"))
            XCTAssertNil(coordinator.listening)
            XCTAssertTrue(fixture.launcher.launched.isEmpty)
        }
    }

    func testEndingBeforeRecognitionStartsCannotReviveListening() async {
        let fixture = await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.auditFile) }
        fixture.coordinator.begin(sessionID: "s1")
        fixture.coordinator.end(sessionID: "s1")
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(fixture.source.startedSessions.isEmpty)
        XCTAssertNil(fixture.coordinator.listening)
        XCTAssertNil(fixture.coordinator.activeSessionID)
    }

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
        XCTAssertEqual(fixture.launcher.awaitedWindows, [false], "Early launches never block on the app's window.")
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
        XCTAssertNil(fixture.coordinator.listening)
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
        XCTAssertNil(fixture.coordinator.listening)
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

    func testDisabledActionsSkipListeningEntirely() async {
        let fixture = await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.auditFile) }
        AppSettings.shared.actionsEnabled = false
        XCTAssertFalse(fixture.coordinator.isEnabled)
        XCTAssertFalse(fixture.coordinator.streamsInterim)
        fixture.coordinator.begin(sessionID: "s1")
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(fixture.source.startedSessions.isEmpty)
        XCTAssertNil(fixture.coordinator.activeSessionID)
        XCTAssertNil(fixture.coordinator.listening)
        XCTAssertNil(fixture.coordinator.take(sessionID: "s1"))
    }

    func testInstantLaunchDisabledStillStreamsWithoutObservingLaunchIntents() async {
        let fixture = await makeFixture()
        defer { fixture.coordinator.end(sessionID: "s1"); try? FileManager.default.removeItem(at: fixture.auditFile) }
        AppSettings.shared.instantAppLaunchEnabled = false
        XCTAssertFalse(fixture.coordinator.isEnabled)
        XCTAssertTrue(fixture.coordinator.streamsInterim)
        fixture.coordinator.begin(sessionID: "s1")
        await waitUntil { fixture.source.isListening }
        fixture.source.emit("Open Notes", sequence: 1)
        fixture.source.emit("Open Notes", sequence: 2)
        await waitUntil { fixture.coordinator.listening?.transcript == "Open Notes" }
        XCTAssertTrue(fixture.launcher.launched.isEmpty)
        XCTAssertNil(fixture.coordinator.activity)
        XCTAssertTrue(fixture.audit.entries().isEmpty)

        AppSettings.shared.instantAppLaunchEnabled = true
        fixture.source.emit("Open Notes app", sequence: 3)
        await waitUntil { fixture.coordinator.listening?.transcript == "Open Notes app" }
        XCTAssertTrue(fixture.launcher.launched.isEmpty, "Partials heard while launch was off must not count toward intent stability.")
        XCTAssertNil(fixture.coordinator.take(sessionID: "s1"))
        XCTAssertNil(fixture.coordinator.listening)
    }

    func testUnsupportedSystemHasNoSource() async {
        let fixture = await makeFixture(source: nil)
        defer { try? FileManager.default.removeItem(at: fixture.auditFile) }
        XCTAssertFalse(fixture.coordinator.isSupported)
        XCTAssertFalse(fixture.coordinator.isEnabled)
        XCTAssertFalse(fixture.coordinator.streamsInterim)
        let availability = await fixture.coordinator.availability()
        XCTAssertEqual(availability, .requiresNewerOS)
        fixture.coordinator.begin(sessionID: "s1")
        XCTAssertNil(fixture.coordinator.activeSessionID)
        XCTAssertNil(fixture.coordinator.listening)
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
        await waitUntil { fixture.source.startedSessions.count == 1 && fixture.coordinator.listening == nil }
        XCTAssertNil(fixture.coordinator.listening)
        XCTAssertNil(fixture.coordinator.activeSessionID)
        XCTAssertNil(fixture.coordinator.take(sessionID: "s1"), "No commit is possible without recognition.")
        XCTAssertTrue(fixture.launcher.launched.isEmpty)
    }

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
        XCTAssertNil(fixture.coordinator.listening)
        XCTAssertNil(fixture.coordinator.activity)
        XCTAssertNil(fixture.coordinator.activeSessionID)
        XCTAssertNil(fixture.coordinator.take(sessionID: "s1"), "An ended session hands nothing over.")

        await waitUntil { !fixture.audit.entries().isEmpty }
        XCTAssertEqual(fixture.audit.entries().map(\.outcome), ["speculative"], "The open request already reached macOS.")
        XCTAssertNil(fixture.coordinator.activity, "A finished launch does not revive the HUD after the session ended.")
        XCTAssertNil(fixture.coordinator.listening)
    }

    func testSessionIdentifiersAreRespected() async {
        let fixture = await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.auditFile) }
        fixture.coordinator.begin(sessionID: "s1")
        await waitUntil { fixture.source.isListening }
        fixture.source.emit("Create a note", sequence: 1)
        await waitUntil { fixture.coordinator.listening?.transcript == "Create a note" }
        fixture.coordinator.end(sessionID: "other")
        XCTAssertEqual(fixture.coordinator.activeSessionID, "s1")
        XCTAssertNil(fixture.coordinator.take(sessionID: "other"))
        XCTAssertEqual(fixture.coordinator.listening, .init(sessionID: "s1", transcript: "Create a note"))
        XCTAssertEqual(fixture.source.stopCount, 0)

        fixture.coordinator.begin(sessionID: "s2")
        XCTAssertEqual(fixture.coordinator.listening, .init(sessionID: "s2", transcript: ""))
        fixture.coordinator.end(sessionID: "s1")
        await waitUntil { fixture.source.startedSessions.count == 2 }
        XCTAssertEqual(fixture.coordinator.activeSessionID, "s2")
        XCTAssertEqual(fixture.source.stopCount, 1, "Starting a new session stops the previous one.")
        fixture.coordinator.end(sessionID: "s2")
        XCTAssertNil(fixture.coordinator.listening)
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
        XCTAssertNil(fixture.coordinator.listening)
    }

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

    func testEngineIsAskedForInterimTextOnlyWhenTheFeatureCanUseIt() async {
        let fixture = await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.auditFile) }
        XCTAssertTrue(fixture.coordinator.wantsInterimTranscripts())
        AppSettings.shared.instantAppLaunchEnabled = false
        XCTAssertTrue(fixture.coordinator.wantsInterimTranscripts(), "The HUD uses previews even when instant launches are off.")
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

    func testPrepareChecksAvailabilityAndPrewarmsOnce() async {
        AppSettings.shared.instantAppLaunchEnabled = false
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
