import XCTest
@testable import Superkeet

final class NativeClauseRouterTests: XCTestCase {
    private let directory = URL(fileURLWithPath: "/fixture/Applications")
    private var notes: URL { directory.appendingPathComponent("Notes.app") }
    private var helium: URL { directory.appendingPathComponent("Helium.app") }

    private func context(currentApp: String? = nil, running: [URL]? = nil) -> NativeClauseContext {
        NativeClauseContext(
            currentApp: currentApp,
            resolveApp: { [directory, notes, helium] name in
                let normalized = AppResolver.normalizedName(name)
                if normalized.contains("notes") { return notes }
                if normalized.contains("helium") { return helium }
                if normalized == "safari" { return directory.appendingPathComponent("Safari.app") }
                return nil
            },
            isRunning: { url in running?.contains(url) ?? true }
        )
    }

    func testOpensAndSwitchesResolveToInstalledApps() {
        XCTAssertEqual(NativeClauseRouter.action(for: "open Notes", context: context()), .openApp(name: "Notes"))
        XCTAssertEqual(NativeClauseRouter.action(for: "can you open up the Notes app for me", context: context()), .openApp(name: "the Notes app"))
        XCTAssertEqual(NativeClauseRouter.action(for: "switch to Helium", context: context()), .openApp(name: "Helium"))
        XCTAssertNil(NativeClauseRouter.action(for: "open Foo", context: context()), "Nothing installed by that name.")
    }

    func testInAppStepsGoToTheCurrentApp() throws {
        let commandN = try XCTUnwrap(KeyboardShortcut(keys: ["cmd", "n"]))
        XCTAssertEqual(NativeClauseRouter.action(for: "create a new note", context: context(currentApp: "Notes")), .pressShortcut(app: "Notes", shortcut: commandN))
        XCTAssertEqual(NativeClauseRouter.action(for: "open a new note", context: context(currentApp: "Notes")), .pressShortcut(app: "Notes", shortcut: commandN))
        XCTAssertEqual(NativeClauseRouter.action(for: "let's make the title say hello", context: context(currentApp: "Notes")), .typeText(app: "Notes", text: "hello"))
        XCTAssertEqual(NativeClauseRouter.action(for: "type hello in Notes", context: context()), .typeText(app: "Notes", text: "hello"))
        XCTAssertNil(NativeClauseRouter.action(for: "create a new note", context: context()), "No current app, no target.")
        XCTAssertNil(NativeClauseRouter.action(for: "save it in Notes", context: context(running: [])), "A named app must be running.")
    }

    func testURLsAndSearchesUseTheBrowserAlreadyOpen() throws {
        let youtube = try XCTUnwrap(URL(string: "https://youtube.com"))
        XCTAssertEqual(NativeClauseRouter.action(for: "go to youtube.com", context: context(currentApp: "Helium")), .openURL(url: youtube, browser: "Helium"))
        XCTAssertEqual(NativeClauseRouter.action(for: "go to youtube.com", context: context(currentApp: "Notes")), .openURL(url: youtube, browser: nil))
        let search = try XCTUnwrap(NativeOpenAction.webSearchURL(for: "Norbert Wiener"))
        XCTAssertEqual(NativeClauseRouter.action(for: "can you Google search Norbert Wiener?", context: context(currentApp: "Helium")), .openURL(url: search, browser: "Helium"))
    }

    func testPlannerOnlyClausesReturnNil() {
        for clause in ["click Save", "summarize the page", "what's on my screen", "In the current Chrome tab, go to youtube.com"] {
            XCTAssertNil(NativeClauseRouter.action(for: clause, context: context(currentApp: "Notes")), clause)
        }
    }
}

final class SpeculativeStepDetectorTests: XCTestCase {
    private let directory = URL(fileURLWithPath: "/fixture/Applications")
    private var notes: URL { directory.appendingPathComponent("Notes.app") }
    private var safari: URL { directory.appendingPathComponent("Safari.app") }
    private var notesApp: SpeculativeApp { SpeculativeApp(spokenName: "notes", url: notes) }

    private func detector(policy: ActionApprovalPolicy = .readOnlyAuto) -> SpeculativeStepDetector {
        SpeculativeStepDetector(environment: .init(
            resolveApp: { [notes, safari] name in
                let normalized = AppResolver.normalizedName(name)
                if normalized.contains("notes") { return notes }
                if normalized == "safari" { return safari }
                return nil
            },
            isRunning: { _ in true },
            allows: { SpeculativeStepDetector.allows($0, policy: policy) }
        ))
    }

    private func feed(_ detector: inout SpeculativeStepDetector, _ texts: [String], launched: SpeculativeApp?, finalLast: Bool = false) -> [[SpeculativeStep]] {
        texts.enumerated().map { offset, text in
            detector.observe(PartialTranscript(text: text, isFinal: finalLast && offset == texts.count - 1, sequence: offset + 1), launchedApp: launched)
        }
    }

    func testClausesRunOnceTheNextClauseHasBegun() throws {
        var detector = detector()
        let commandN = try XCTUnwrap(KeyboardShortcut(keys: ["cmd", "n"]))
        let results = feed(&detector, [
            "Open Notes",
            "Open Notes and create",
            "Open Notes and create a new note and make",
            "Open Notes and create a new note and make the title say hello and open Safari"
        ], launched: notesApp)
        XCTAssertEqual(results[0], [])
        XCTAssertEqual(results[1], [], "The launch detector already opened Notes; the second clause is still being spoken.")
        XCTAssertEqual(results[2], [SpeculativeStep(index: 1, clause: "create a new note", action: .pressShortcut(app: "Notes", shortcut: commandN), sequence: 3)])
        XCTAssertEqual(results[3], [SpeculativeStep(index: 2, clause: "make the title say hello", action: .typeText(app: "Notes", text: "hello"), sequence: 4)])
        XCTAssertEqual(detector.steps.count, 2)
        XCTAssertEqual(detector.handled, 3)
        XCTAssertFalse(detector.blocked, "\"open Safari\" is the last clause and still open.")
    }

    func testFinalTextCompletesTheLastClause() {
        var detector = detector()
        let results = feed(&detector, ["Open Notes and open Safari"], launched: notesApp, finalLast: true)
        XCTAssertEqual(results[0].map(\.action), [.openApp(name: "Safari")])
    }

    func testAPlannerClauseStopsEarlyExecutionForTheRest() {
        var detector = detector()
        let results = feed(&detector, ["Open Notes and click Save and type hello and"], launched: notesApp)
        XCTAssertEqual(results[0], [], "click needs the planner, and typing must not jump ahead of it.")
        XCTAssertTrue(detector.blocked)
        XCTAssertEqual(feed(&detector, ["Open Notes and click Save and type hello and open Safari and"], launched: notesApp)[0], [])
    }

    func testPolicyThatWouldAskKeepsInAppStepsForLater() {
        var asking = detector(policy: .alwaysAsk)
        let results = feed(&asking, ["Open Notes and create a new note and type hello and"], launched: notesApp)
        XCTAssertEqual(results[0], [])
        XCTAssertTrue(asking.blocked)

        var yolo = detector(policy: .autoApprove)
        let ran = feed(&yolo, ["Open Notes and create a new note and save it and type hello and"], launched: notesApp)[0]
        XCTAssertEqual(ran.map(\.action.toolName), ["press_shortcut", "press_shortcut", "type_text"], "Just Do It runs ⌘S early too.")
    }

    func testAppsOpenedByStepsBecomeTheCurrentApp() throws {
        var detector = detector()
        let commandN = try XCTUnwrap(KeyboardShortcut(keys: ["cmd", "n"]))
        let ran = feed(&detector, ["Open Safari and open Notes and create a new note and"], launched: SpeculativeApp(spokenName: "safari", url: safari))[0]
        XCTAssertEqual(ran.map(\.action), [.openApp(name: "Notes"), .pressShortcut(app: "Notes", shortcut: commandN)])
    }

    func testStalePartialsAreIgnored() {
        var detector = detector()
        _ = detector.observe(PartialTranscript(text: "Open Notes and create a new note and type", isFinal: false, sequence: 5), launchedApp: notesApp)
        let stale = detector.observe(PartialTranscript(text: "Open Notes and create a new note and type hello and open Safari", isFinal: false, sequence: 4), launchedApp: notesApp)
        XCTAssertEqual(stale, [])
        XCTAssertEqual(detector.steps.count, 1)
    }

    // MARK: Last clause while still speaking

    private func notesDetector(installed: [String] = []) -> SpeculativeStepDetector {
        SpeculativeStepDetector(environment: .init(
            resolveApp: { [notes, safari] name in
                let normalized = AppResolver.normalizedName(name)
                if normalized.contains("notes") { return notes }
                if normalized == "safari" { return safari }
                return nil
            },
            isRunning: { _ in true },
            allows: { SpeculativeStepDetector.allows($0, policy: .readOnlyAuto) },
            installedNames: { installed }
        ))
    }

    func testLastClauseRunsWhenASecondPartialConfirmsIt() throws {
        var detector = notesDetector()
        let commandN = try XCTUnwrap(KeyboardShortcut(keys: ["cmd", "n"]))
        let results = feed(&detector, ["Open the Notes app and create a new no", "Open the Notes app and create a new note"], launched: notesApp)
        XCTAssertEqual(results[0], [], "One sighting is not enough while the words are still coming.")
        XCTAssertEqual(results[1], [SpeculativeStep(index: 1, clause: "create a new note", action: .pressShortcut(app: "Notes", shortcut: commandN), sequence: 2)])
        XCTAssertNil(detector.trailingDeadline)
    }

    func testLastClauseRunsOnceItHoldsStillWithoutANewPartial() throws {
        var detector = notesDetector()
        let start = Date(timeIntervalSince1970: 100)
        let commandN = try XCTUnwrap(KeyboardShortcut(keys: ["cmd", "n"]))
        let first = detector.observe(PartialTranscript(text: "Open the Notes app and create a new note", isFinal: false, sequence: 1), launchedApp: notesApp, at: start)
        XCTAssertEqual(first, [])
        XCTAssertEqual(detector.trailingDeadline, start.addingTimeInterval(SpeculativeStepDetector.trailingHold))
        XCTAssertEqual(detector.commitStableTrailing(at: start.addingTimeInterval(0.3)), [])
        let held = detector.commitStableTrailing(at: start.addingTimeInterval(SpeculativeStepDetector.trailingHold))
        XCTAssertEqual(held.map(\.action), [.pressShortcut(app: "Notes", shortcut: commandN)])
        XCTAssertEqual(detector.commitStableTrailing(at: start.addingTimeInterval(5)), [], "Runs once.")
        XCTAssertEqual(feed(&detector, ["", "Open the Notes app and create a new note and"], launched: notesApp)[1], [], "Not repeated when the clause completes.")
    }

    func testAChangingLastClauseRestartsTheHold() throws {
        var detector = notesDetector()
        let start = Date(timeIntervalSince1970: 100)
        _ = detector.observe(PartialTranscript(text: "Open Notes and create a new tab", isFinal: false, sequence: 1), launchedApp: notesApp, at: start)
        let later = start.addingTimeInterval(0.5)
        let changed = detector.observe(PartialTranscript(text: "Open Notes and create a new tabular note", isFinal: false, sequence: 2), launchedApp: notesApp, at: later)
        XCTAssertEqual(changed, [], "⌘T then ⌘N: different actions, nothing is confirmed.")
        XCTAssertEqual(detector.commitStableTrailing(at: start.addingTimeInterval(SpeculativeStepDetector.trailingHold)), [])
        XCTAssertEqual(detector.trailingDeadline, later.addingTimeInterval(SpeculativeStepDetector.trailingHold))
    }

    func testTypingAndUnfinishedSearchesNeverRunBeforeTheSpeakerMovesOn() {
        for text in ["Open Notes and type hello", "Open Notes and type hello.", "Open Notes and google search Norbert"] {
            var detector = notesDetector()
            let start = Date(timeIntervalSince1970: 100)
            XCTAssertEqual(detector.observe(PartialTranscript(text: text, isFinal: false, sequence: 1), launchedApp: notesApp, at: start), [])
            XCTAssertNil(detector.trailingDeadline, text)
            XCTAssertEqual(detector.commitStableTrailing(at: start.addingTimeInterval(10)), [], text)
            XCTAssertEqual(feed(&detector, ["", "\(text) please"], launched: notesApp)[1], [], "\(text): a second sighting doesn't help either")
        }
    }

    func testSearchRunsOnceTheRecogniserEndsTheSentence() throws {
        var detector = notesDetector()
        let start = Date(timeIntervalSince1970: 100)
        let search = try XCTUnwrap(NativeOpenAction.webSearchURL(for: "Norbert Wiener"))
        _ = detector.observe(PartialTranscript(text: "Open Notes and google search Norbert Wiener?", isFinal: false, sequence: 1), launchedApp: notesApp, at: start)
        XCTAssertEqual(detector.commitStableTrailing(at: start.addingTimeInterval(1)).map(\.action), [.openURL(url: search, browser: nil)])
    }

    func testExplicitWebsiteMayRunWhileSpokenButSearchMayNot() throws {
        XCTAssertFalse(SpeculativeStepDetector.isOpenEndedSearch(try XCTUnwrap(URL(string: "https://x.com"))))
        XCTAssertTrue(SpeculativeStepDetector.isOpenEndedSearch(try XCTUnwrap(NativeOpenAction.webSearchURL(for: "Norbert"))))
    }

    func testTrailingOpenWaitsWhileALongerAppNameIsPossible() {
        var detector = notesDetector(installed: ["Notes", "Safari", "Safari Technology Preview"])
        let start = Date(timeIntervalSince1970: 100)
        _ = detector.observe(PartialTranscript(text: "Open Notes and open Safari", isFinal: false, sequence: 1), launchedApp: notesApp, at: start)
        XCTAssertNil(detector.trailingDeadline, "\"Safari\" may still become \"Safari Technology Preview\".")

        var plain = notesDetector(installed: ["Notes", "Safari"])
        _ = plain.observe(PartialTranscript(text: "Open Notes and open Safari", isFinal: false, sequence: 1), launchedApp: notesApp, at: start)
        XCTAssertEqual(plain.commitStableTrailing(at: start.addingTimeInterval(1)).map(\.action), [.openApp(name: "Safari")])
    }

    func testAPlannerClauseStopIsLiftedWhenTheRecogniserCorrectsIt() throws {
        var detector = notesDetector()
        let commandN = try XCTUnwrap(KeyboardShortcut(keys: ["cmd", "n"]))
        let results = feed(&detector, ["Open Notes and umce and", "Open Notes and create a new note and"], launched: notesApp)
        XCTAssertEqual(results[0], [])
        XCTAssertEqual(results[1].map(\.action), [.pressShortcut(app: "Notes", shortcut: commandN)])
        XCTAssertFalse(detector.blocked)
    }

    func testARewrittenFinishedClauseStopsEarlyExecution() {
        var detector = notesDetector()
        let results = feed(&detector, [
            "Open Notes and create a new note and",
            "Open Notes and create a new tab and type hello and"
        ], launched: notesApp)
        XCTAssertEqual(results[0].count, 1)
        XCTAssertEqual(results[1], [], "⌘N already ran for a clause that now means ⌘T; positions can't be trusted.")
        XCTAssertTrue(detector.diverged)
    }

    func testDemoTranscriptRunsTheNewNoteDespiteTheGarbledWords() throws {
        var detector = notesDetector()
        let commandN = try XCTUnwrap(KeyboardShortcut(keys: ["cmd", "n"]))
        let ran = feed(&detector, ["Alright, can you open up the notes app for me and umce right there can you create a new note? And um inside this new note, let's make"], launched: notesApp)[0]
        XCTAssertEqual(ran.map(\.action), [.pressShortcut(app: "Notes", shortcut: commandN)])
    }

    func testAllowsMirrorsTheApprovalPolicy() throws {
        let commandS = try XCTUnwrap(KeyboardShortcut(keys: ["cmd", "s"]))
        XCTAssertTrue(SpeculativeStepDetector.allows(.openApp(name: "Notes"), policy: .alwaysAsk))
        XCTAssertTrue(SpeculativeStepDetector.allows(.typeText(app: "Notes", text: "x"), policy: .readOnlyAuto))
        XCTAssertFalse(SpeculativeStepDetector.allows(.pressShortcut(app: "Notes", shortcut: commandS), policy: .readOnlyAuto))
        XCTAssertTrue(SpeculativeStepDetector.allows(.pressShortcut(app: "Notes", shortcut: commandS), policy: .autoApprove))
        XCTAssertFalse(SpeculativeStepDetector.allows(.typeText(app: "Notes", text: "x"), policy: .alwaysAsk))
    }

    func testStepResultDescriptions() throws {
        let commandN = try XCTUnwrap(KeyboardShortcut(keys: ["cmd", "n"]))
        let step = SpeculativeStep(index: 1, clause: "create a new note", action: .pressShortcut(app: "Notes", shortcut: commandN), sequence: 3)
        let done = SpeculativeStepResult(step: step, output: "Pressed ⌘N in Notes (pid 91).", failure: nil)
        XCTAssertEqual(done.summary, "Press ⌘N in Notes")
        XCTAssertEqual(done.doneDescription, "Pressed ⌘N in Notes")
        let opened = SpeculativeStepResult(step: step, output: NativeLaunchedApp(name: "Notes", bundleIdentifier: "com.apple.Notes", processIdentifier: 9, windowReady: true).summary, failure: nil)
        XCTAssertEqual(opened.doneDescription, "Opened Notes")
        let failed = SpeculativeStepResult(step: step, output: nil, failure: "Notes is not running")
        XCTAssertEqual(failed.doneDescription, "Press ⌘N in Notes")
        XCTAssertFalse(failed.succeeded)
    }
}

@MainActor
final class SpeculativeStepExecutionTests: XCTestCase {
    final class FakeExecutor: NativeActionExecuting {
        private(set) var executed: [NativeOpenAction] = []
        var failure: Error?
        func execute(_ action: NativeOpenAction) async throws -> String {
            executed.append(action)
            if let failure { throw failure }
            switch action {
            case .pressShortcut(let app, let shortcut): return "Pressed \(shortcut.displayName) in \(app) (pid 4242)."
            case .typeText(let app, let text): return "Typed “\(text)” in \(app) (pid 4242)."
            case .openApp(let name): return NativeLaunchedApp(name: name, bundleIdentifier: nil, processIdentifier: 4243, windowReady: true).summary
            case .openURL(let url, let browser): return "Opened \(url.absoluteString) in \(browser ?? "the default browser")."
            }
        }
    }

    private nonisolated(unsafe) var saved: (actions: Bool, instant: Bool, audit: Bool, policy: ActionApprovalPolicy)?

    override func setUp() {
        super.setUp()
        let settings = AppSettings.shared
        saved = (settings.actionsEnabled, settings.instantAppLaunchEnabled, settings.actionAuditEnabled, settings.actionApprovalPolicy)
        settings.actionsEnabled = true
        settings.instantAppLaunchEnabled = true
        settings.actionAuditEnabled = true
        settings.actionApprovalPolicy = .readOnlyAuto
    }

    override func tearDown() {
        if let saved {
            AppSettings.shared.actionsEnabled = saved.actions
            AppSettings.shared.instantAppLaunchEnabled = saved.instant
            AppSettings.shared.actionAuditEnabled = saved.audit
            AppSettings.shared.actionApprovalPolicy = saved.policy
        }
        super.tearDown()
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testCoordinatorRunsCompletedClausesInOrderWhileSpeaking() async throws {
        let directory = URL(fileURLWithPath: "/fixture/Applications")
        let apps = ["Notes", "Safari"].map { directory.appendingPathComponent("\($0).app") }
        let inventory = InstalledAppInventory(
            makeResolver: { AppResolver(directories: [directory], applicationsInDirectory: { _ in apps }) },
            bundleLookup: { _ in nil }, runningBundleURLs: { apps }
        )
        _ = await inventory.waitUntilReady(timeout: .seconds(5))
        let auditFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        defer { try? FileManager.default.removeItem(at: auditFile) }
        let audit = ActionAuditStore(fileURL: auditFile)
        let source = SpeculativeLaunchCoordinatorTests.FakeSource()
        let launcher = SpeculativeLaunchCoordinatorTests.FakeLauncher()
        let executor = FakeExecutor()
        var awaited: [Int32] = []
        let coordinator = SpeculativeLaunchCoordinator(
            settings: .shared, source: source, inventory: inventory, launcher: launcher, executor: executor,
            awaitWindow: { awaited.append($0); return true }, audit: audit
        )
        defer { coordinator.end(sessionID: "s1") }

        coordinator.begin(sessionID: "s1")
        await waitUntil { source.isListening }
        source.emit("Open Notes", sequence: 1)
        source.emit("Open Notes and create", sequence: 2)
        await waitUntil { launcher.launched.count == 1 }
        source.emit("Open Notes and create a new note and make", sequence: 3)
        source.emit("Open Notes and create a new note and make the title say hello and open Safari", sequence: 4)
        await waitUntil { executor.executed.count == 2 }

        let commandN = try XCTUnwrap(KeyboardShortcut(keys: ["cmd", "n"]))
        XCTAssertEqual(executor.executed, [.pressShortcut(app: "Notes", shortcut: commandN), .typeText(app: "Notes", text: "hello")])
        XCTAssertEqual(launcher.launched, [apps[0]], "Safari is the last clause; it waits until it has held still.")
        XCTAssertEqual(awaited, [], "The fake launch reports its window ready, so nothing waits.")
        if case .done(let result)? = coordinator.stepActivity {
            XCTAssertEqual(result.doneDescription, "Typed “hello” in Notes")
        } else {
            XCTFail("Expected the last step to be reported done, got \(String(describing: coordinator.stepActivity))")
        }

        XCTAssertEqual(coordinator.stepActivities.map(\.step.index), [1, 2], "Every early step stays listed, not just the last.")
        XCTAssertTrue(coordinator.stepActivities.allSatisfy { if case .done = $0 { return true } else { return false } })

        let handoff = try XCTUnwrap(coordinator.takeHandoff(sessionID: "s1"))
        XCTAssertTrue(coordinator.stepActivities.isEmpty)
        XCTAssertNotNil(handoff.launch)
        XCTAssertEqual(handoff.steps.map(\.step.index), [1, 2])
        XCTAssertNil(coordinator.stepActivity)
        for run in handoff.steps {
            let result = await run.result()
            XCTAssertTrue(result.succeeded, result.step.clause)
        }
        let entries = audit.entries()
        XCTAssertEqual(entries.map(\.toolName), ["open_app", "press_shortcut", "type_text"])
        XCTAssertEqual(entries.map(\.outcome), ["speculative", "speculative", "speculative"])
        XCTAssertTrue(entries[1].detail?.contains("clause #2") ?? false)
        XCTAssertNotNil(entries[1].sinceCommandMs, "Latency counts from the recording start.")
    }

    func testCoordinatorRunsAStableLastClauseBeforeTheSpeakerStops() async throws {
        let directory = URL(fileURLWithPath: "/fixture/Applications")
        let apps = ["Notes"].map { directory.appendingPathComponent("\($0).app") }
        let inventory = InstalledAppInventory(
            makeResolver: { AppResolver(directories: [directory], applicationsInDirectory: { _ in apps }) },
            bundleLookup: { _ in nil }, runningBundleURLs: { apps }
        )
        _ = await inventory.waitUntilReady(timeout: .seconds(5))
        let auditFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        defer { try? FileManager.default.removeItem(at: auditFile) }
        let source = SpeculativeLaunchCoordinatorTests.FakeSource()
        let launcher = SpeculativeLaunchCoordinatorTests.FakeLauncher()
        let executor = FakeExecutor()
        let coordinator = SpeculativeLaunchCoordinator(
            settings: .shared, source: source, inventory: inventory, launcher: launcher, executor: executor,
            awaitWindow: { _ in true }, audit: ActionAuditStore(fileURL: auditFile)
        )
        defer { coordinator.end(sessionID: "s1") }

        coordinator.begin(sessionID: "s1")
        await waitUntil { source.isListening }
        source.emit("Open the Notes app", sequence: 1)
        source.emit("Open the Notes app and create a new note", sequence: 2)
        await waitUntil { launcher.launched.count == 1 }
        XCTAssertEqual(executor.executed, [], "Nothing else has been said yet, but the last clause hasn't held still.")
        await waitUntil(timeout: 3) { executor.executed.count == 1 }

        let commandN = try XCTUnwrap(KeyboardShortcut(keys: ["cmd", "n"]))
        XCTAssertEqual(executor.executed, [.pressShortcut(app: "Notes", shortcut: commandN)], "⌘N ran with no pause and no final transcript.")
        let handoff = try XCTUnwrap(coordinator.takeHandoff(sessionID: "s1"))
        XCTAssertEqual(handoff.steps.map(\.step.index), [1])
    }

    func testControllerSkipsClausesThatRanEarlyAndRerunsFailedOnes() async throws {
        let notes = URL(fileURLWithPath: "/fixture/Applications/Notes.app")
        let commandN = try XCTUnwrap(KeyboardShortcut(keys: ["cmd", "n"]))
        let commit = SpeculativeCommit(action: .launch(SpeculativeApp(spokenName: "notes", url: notes)), clause: "open notes", sequence: 2, reason: .clauseBoundary)
        let launch = SpeculativeLaunch(commit: commit, disagreement: false, outcome: Task {
            .success(NativeLaunchedApp(name: "Notes", bundleIdentifier: "com.apple.Notes", processIdentifier: 77, windowReady: true))
        })
        let step = SpeculativeStep(index: 1, clause: "create a new note", action: .pressShortcut(app: "Notes", shortcut: commandN), sequence: 3)

        for earlySucceeded in [true, false] {
            let run = SpeculativeStepRun(step: step, outcome: Task {
                earlySucceeded ? .success("Pressed ⌘N in Notes (pid 77).") : .failure(NativeOpenActionError.appNotRunning("Notes"))
            })
            let router = AgentSessionControllerTests.FakeRouter(specs: [])
            router.preparationFailure = ActionExecutionError.noMCPServersEnabled
            router.outputs["press_shortcut"] = "Pressed ⌘N in Notes (pid 77)."
            router.outputs["type_text"] = "Typed “hello” in Notes (pid 77)."
            let controller = AgentSessionController(
                settings: .shared, router: router, plannerFactory: { nil },
                resolveApp: { AppResolver.normalizedName($0).contains("notes") ? notes : nil }, isAppRunning: { $0 == notes },
                frontmostApp: { nil }
            )
            controller.handleCommand(
                "open the notes app and create a new note and make the title say hello",
                handoff: SpeculativeHandoff(launch: launch, steps: [run])
            )
            let deadline = Date().addingTimeInterval(5)
            while controller.phase.isActive && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }

            if earlySucceeded {
                XCTAssertEqual(router.executed, ["type_text"], "Open and ⌘N both happened while the user was speaking.")
                XCTAssertTrue(controller.activityLog.contains("Pressed ⌘N in Notes while you were speaking"), "\(controller.activityLog)")
                XCTAssertTrue(controller.activityLog.contains("Already done: Pressed ⌘N in Notes"), "\(controller.activityLog)")
            } else {
                XCTAssertEqual(router.executed, ["press_shortcut", "type_text"], "A failed early step is simply done again.")
                XCTAssertTrue(controller.activityLog.contains { $0.hasPrefix("Couldn't press ⌘N in Notes early") }, "\(controller.activityLog)")
            }
            if case .finished = controller.phase {} else { XCTFail("Expected success, got \(controller.phase)") }
        }
    }

    func testSingleClauseThatRanEarlyFinishesWithoutRunningAgain() async throws {
        let helium = URL(fileURLWithPath: "/fixture/Applications/Helium.app")
        let search = try XCTUnwrap(NativeOpenAction.webSearchURL(for: "Norbert Wiener"))
        let step = SpeculativeStep(index: 0, clause: "google search Norbert Wiener", action: .openURL(url: search, browser: nil), sequence: 2)
        let run = SpeculativeStepRun(step: step, outcome: Task { .success("Opened \(search.absoluteString) in the default browser.") })
        let router = AgentSessionControllerTests.FakeRouter(specs: [])
        let controller = AgentSessionController(
            settings: .shared, router: router, plannerFactory: { nil },
            resolveApp: { AppResolver.normalizedName($0).contains("helium") ? helium : nil }, isAppRunning: { _ in true },
            frontmostApp: { nil }
        )
        controller.handleCommand("Google search Norbert Wiener.", handoff: SpeculativeHandoff(launch: nil, steps: [run]))
        let deadline = Date().addingTimeInterval(5)
        while controller.phase.isActive && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }

        XCTAssertEqual(router.executed, [])
        XCTAssertEqual(controller.phase, .finished("Opened \(search.absoluteString) in the default browser."))
    }
}
