import Combine
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
        XCTAssertEqual(results[3], [
            SpeculativeStep(index: 2, clause: "make the title say hello", action: .typeText(app: "Notes", text: "hello"), sequence: 4),
            SpeculativeStep(index: 3, clause: "open Safari", action: .openApp(name: "Safari"), sequence: 4)
        ], "\"open Safari\" is still being spoken, but an open runs on its first unambiguous sighting.")
        XCTAssertEqual(detector.steps.count, 3)
        XCTAssertEqual(detector.handled, 4)
        XCTAssertFalse(detector.blocked)
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

    private func notesDetector(installed: [String] = [], stabilityThreshold: Int = 1) -> SpeculativeStepDetector {
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
        ), stabilityThreshold: stabilityThreshold)
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

    func testALaterClauseOpenRunsOnItsFirstSightingButAnAmbiguousNameWaits() {
        let start = Date(timeIntervalSince1970: 100)
        var plain = notesDetector(installed: ["Notes", "Safari"])
        let opened = plain.observe(PartialTranscript(text: "Open Notes and open Safari", isFinal: false, sequence: 1), launchedApp: notesApp, at: start)
        XCTAssertEqual(opened.map(\.action), [.openApp(name: "Safari")], "No second partial and no hold.")

        var ambiguous = notesDetector(installed: ["Notes", "Safari", "Safari Technology Preview"])
        let waiting = ambiguous.observe(PartialTranscript(text: "Open Notes and open Safari", isFinal: false, sequence: 1), launchedApp: notesApp, at: start)
        XCTAssertEqual(waiting, [], "\"Safari\" may still become \"Safari Technology Preview\".")
        XCTAssertNil(ambiguous.trailingDeadline)
        XCTAssertEqual(ambiguous.observe(EngineTick(sessionID: "s", audio: .seconds(3), trailingSilence: .seconds(2))), [], "Not even a long silence settles a name that could grow.")
        XCTAssertEqual(ambiguous.commitStableTrailing(at: start.addingTimeInterval(10)), [])
        let moved = ambiguous.observe(PartialTranscript(text: "Open Notes and open Safari and", isFinal: false, sequence: 2), launchedApp: notesApp, at: start)
        XCTAssertEqual(moved.map(\.action), [.openApp(name: "Safari")], "Once the speaker moves on the name is whole.")
    }

    func testALaterOpenWaitsForAsManySightingsAsTheLeadingLaunch() throws {
        var detector = notesDetector(installed: ["Notes", "Safari"], stabilityThreshold: 2)
        let opened = feed(&detector, ["Open Notes and open Safari", "Open Notes and open Safari"], launched: notesApp)
        XCTAssertEqual(opened[0], [], "The launch needs two sightings, so a later open does too.")
        XCTAssertEqual(opened[1].map(\.action), [.openApp(name: "Safari")])

        var site = notesDetector(stabilityThreshold: 2)
        let xcom = try XCTUnwrap(URL(string: "https://x.com"))
        let page = feed(&site, ["Open Notes and go to x.com", "Open Notes and go to x.com"], launched: notesApp)
        XCTAssertEqual(page[0], [])
        XCTAssertEqual(page[1].map(\.action), [.openURL(url: xcom, browser: nil)])
    }

    func testAPageNamedBeforeItsBrowserOpensOnce() throws {
        var detector = notesDetector(installed: ["Notes", "Safari"])
        let xcom = try XCTUnwrap(URL(string: "https://x.com"))
        let opened = feed(&detector, ["Open Notes and go to x.com", "Open Notes and go to x.com in Safari."], launched: notesApp)
        XCTAssertEqual(opened[0], [], "\"in Safari\" could still follow; opening now would open the page twice.")
        XCTAssertEqual(opened[1].map(\.action), [.openURL(url: xcom, browser: "Safari")])

        var held = notesDetector(installed: ["Notes", "Safari"])
        let start = Date(timeIntervalSince1970: 100)
        _ = held.observe(PartialTranscript(text: "Open Notes and go to x.com", isFinal: false, sequence: 1), launchedApp: notesApp, at: start)
        XCTAssertEqual(held.commitStableTrailing(at: start.addingTimeInterval(0.8)).map(\.action), [.openURL(url: xcom, browser: nil)],
                       "A page nobody qualifies still opens once the speaker holds still.")
    }

    func testALaterClauseWebsiteOpensOnSightOnceItsSentenceEndsButSearchesAndGrowingAddressesDoNot() throws {
        let start = Date(timeIntervalSince1970: 100)
        var site = notesDetector()
        let opened = site.observe(PartialTranscript(text: "Open Notes and go to x.com.", isFinal: false, sequence: 1), launchedApp: notesApp, at: start)
        XCTAssertEqual(opened.map(\.action), [.openURL(url: try XCTUnwrap(URL(string: "https://x.com")), browser: nil)])

        var growing = notesDetector()
        let early = growing.observe(PartialTranscript(text: "Open Notes and go to x dot co", isFinal: false, sequence: 1), launchedApp: notesApp, at: start)
        XCTAssertEqual(early, [], "\"x.co\" may still become \"x.com\".")
        XCTAssertNotNil(growing.trailingDeadline, "It settles like a shortcut: a confirming partial or the hold.")
        let confirmed = growing.observe(PartialTranscript(text: "Open Notes and go to x dot co", isFinal: false, sequence: 2), launchedApp: notesApp, at: start.addingTimeInterval(0.5))
        XCTAssertEqual(confirmed.map(\.action.toolName), ["open_url"])

        var search = notesDetector()
        XCTAssertEqual(search.observe(PartialTranscript(text: "Open Notes and google search Norbert Wiener", isFinal: false, sequence: 1), launchedApp: notesApp, at: start), [])
    }

    private func tick(silence: Int, session: String = "s") -> EngineTick {
        EngineTick(sessionID: session, audio: .seconds(5), trailingSilence: .milliseconds(silence))
    }

    func testATrailingShortcutRunsOnTheFirstTickWithEnoughSilenceAfterTheSentenceEnds() throws {
        let commandN = try XCTUnwrap(KeyboardShortcut(keys: ["cmd", "n"]))
        var detector = notesDetector()
        let start = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(detector.observe(PartialTranscript(text: "Open the Notes app and create a new note?", isFinal: false, sequence: 1), launchedApp: notesApp, at: start), [])
        XCTAssertEqual(detector.observe(tick(silence: 0)), [])
        XCTAssertEqual(detector.observe(tick(silence: 299)), [], "299 ms is not enough.")
        let ran = detector.observe(tick(silence: 300))
        XCTAssertEqual(ran, [SpeculativeStep(index: 1, clause: "create a new note", action: .pressShortcut(app: "Notes", shortcut: commandN), sequence: 1)])
        XCTAssertEqual(detector.observe(tick(silence: 900)), [], "Runs once.")
        XCTAssertNil(detector.trailingDeadline)
    }

    func testTheSilenceBeforeThePartialAlreadyCountsWhenThePartialEndsTheSentence() {
        var detector = notesDetector()
        XCTAssertEqual(detector.observe(tick(silence: 400)), [])
        let ran = detector.observe(PartialTranscript(text: "Open the Notes app and create a new note?", isFinal: false, sequence: 1), launchedApp: notesApp)
        XCTAssertEqual(ran.map(\.action.toolName), ["press_shortcut"], "The engine sends the tick of a take's audio before the partial decoded from it.")
    }

    func testSilenceAloneNeverRunsAClauseThatDoesNotEndTheSentence() {
        for text in ["Open the Notes app and create a new note", "Open the Notes app and create a new note,", "Open the Notes app and type hello"] {
            var detector = notesDetector()
            _ = detector.observe(PartialTranscript(text: text, isFinal: false, sequence: 1), launchedApp: notesApp)
            XCTAssertEqual(detector.observe(tick(silence: 2_000)), [], text)
        }
    }

    func testATrailingSearchAndTypingRunOnTheTickLikeAShortcut() throws {
        let search = try XCTUnwrap(NativeOpenAction.webSearchURL(for: "Norbert Wiener"))
        var searching = notesDetector()
        _ = searching.observe(PartialTranscript(text: "Open Notes and google search Norbert Wiener?", isFinal: false, sequence: 1), launchedApp: notesApp)
        XCTAssertEqual(searching.observe(tick(silence: 299)), [])
        XCTAssertEqual(searching.observe(tick(silence: 300)).map(\.action), [.openURL(url: search, browser: nil)])

        var typing = notesDetector()
        _ = typing.observe(PartialTranscript(text: "Open Notes and let's make the title say hello.", isFinal: false, sequence: 1), launchedApp: notesApp)
        XCTAssertEqual(typing.observe(tick(silence: 100)), [])
        XCTAssertNil(typing.trailingDeadline, "Typing never waits on the hold; only measured silence releases it.")
        XCTAssertEqual(typing.observe(tick(silence: 352)).map(\.action), [.typeText(app: "Notes", text: "hello")])
    }

    func testAnEngineWithoutTicksKeepsTheConfirmationAndHoldRules() {
        var detector = notesDetector()
        let start = Date(timeIntervalSince1970: 100)
        let first = detector.observe(PartialTranscript(text: "Open the Notes app and create a new note?", isFinal: false, sequence: 1), launchedApp: notesApp, at: start)
        XCTAssertEqual(first, [])
        XCTAssertEqual(detector.trailingDeadline, start.addingTimeInterval(SpeculativeStepDetector.trailingHold))
        XCTAssertEqual(detector.commitStableTrailing(at: start.addingTimeInterval(SpeculativeStepDetector.trailingHold)).map(\.action.toolName), ["press_shortcut"])
    }

    func testAClauseThatCompletesWhileWaitingForSilenceRunsOnceNotTwice() {
        var detector = notesDetector()
        _ = detector.observe(PartialTranscript(text: "Open the Notes app and create a new tab?", isFinal: false, sequence: 1), launchedApp: notesApp)
        let ran = detector.observe(PartialTranscript(text: "Open the Notes app and create a new tab and type", isFinal: false, sequence: 2), launchedApp: notesApp)
        XCTAssertEqual(ran.map(\.action.toolName), ["press_shortcut"], "The speaker moved on before any silence, which completes the clause.")
        XCTAssertEqual(detector.observe(tick(silence: 800)), [], "Nothing is left waiting.")
    }

    func testTheTickReleasesTheLatestReadingOfTheClauseNotAnEarlierOne() throws {
        let commandN = try XCTUnwrap(KeyboardShortcut(keys: ["cmd", "n"]))
        var detector = notesDetector()
        _ = detector.observe(PartialTranscript(text: "Open the Notes app and create a new tab?", isFinal: false, sequence: 1), launchedApp: notesApp)
        _ = detector.observe(PartialTranscript(text: "Open the Notes app and create a new note?", isFinal: false, sequence: 2), launchedApp: notesApp)
        let ran = detector.observe(tick(silence: 500))
        XCTAssertEqual(ran.map(\.action), [.pressShortcut(app: "Notes", shortcut: commandN)], "The tick releases what the latest partial says, not an earlier reading.")
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
        let search = try XCTUnwrap(URL(string: "https://example.com"))
        XCTAssertFalse(SpeculativeStepDetector.allows(.openApp(name: "Notes"), policy: .alwaysAsk), "Ask Before Every Tool means nothing runs unasked.")
        XCTAssertFalse(SpeculativeStepDetector.allows(.openURL(url: search, browser: nil), policy: .alwaysAsk))
        XCTAssertTrue(SpeculativeStepDetector.allows(.openApp(name: "Notes"), policy: .readOnlyAuto))
        XCTAssertTrue(SpeculativeStepDetector.allows(.openURL(url: search, browser: nil), policy: .readOnlyAuto))
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
        private(set) var completed: [NativeOpenAction] = []
        var failure: Error?
        var delay: Duration = .zero
        func execute(_ action: NativeOpenAction) async throws -> String {
            executed.append(action)
            if delay > .zero { try await Task.sleep(for: delay) }
            if let failure { throw failure }
            completed.append(action)
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
        await waitUntil { executor.executed.count == 3 }

        let commandN = try XCTUnwrap(KeyboardShortcut(keys: ["cmd", "n"]))
        XCTAssertEqual(executor.executed, [.pressShortcut(app: "Notes", shortcut: commandN), .typeText(app: "Notes", text: "hello"), .openApp(name: "Safari")])
        XCTAssertEqual(launcher.launched, [apps[0]], "Only the leading open goes through the launcher; Safari is an early step.")
        XCTAssertEqual(awaited, [], "The fake launch reports its window ready, so nothing waits.")
        if case .done(let result)? = coordinator.stepActivity {
            XCTAssertEqual(result.doneDescription, "Opened Safari")
        } else {
            XCTFail("Expected the last step to be reported done, got \(String(describing: coordinator.stepActivity))")
        }

        XCTAssertEqual(coordinator.stepActivities.map(\.step.index), [1, 2, 3], "Every early step stays listed, not just the last.")
        XCTAssertTrue(coordinator.stepActivities.allSatisfy { if case .done = $0 { return true } else { return false } })

        let handoff = try XCTUnwrap(coordinator.takeHandoff(sessionID: "s1"))
        XCTAssertTrue(coordinator.stepActivities.isEmpty)
        XCTAssertNotNil(handoff.launch)
        XCTAssertEqual(handoff.steps.map(\.step.index), [1, 2, 3])
        XCTAssertNil(coordinator.stepActivity)
        for run in handoff.steps {
            let result = await run.result()
            XCTAssertTrue(result.succeeded, result.step.clause)
        }
        let entries = audit.entries()
        XCTAssertEqual(entries.map(\.toolName), ["open_app", "press_shortcut", "type_text", "open_app"])
        XCTAssertEqual(entries.map(\.outcome), ["speculative", "speculative", "speculative", "speculative"])
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

    func testEndingTheSessionCancelsEarlyStepsStillRunning() async throws {
        let directory = URL(fileURLWithPath: "/fixture/Applications")
        let apps = ["Notes"].map { directory.appendingPathComponent("\($0).app") }
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
        executor.delay = .seconds(30)
        let coordinator = SpeculativeLaunchCoordinator(
            settings: .shared, source: source, inventory: inventory, launcher: launcher, executor: executor,
            awaitWindow: { _ in true }, audit: audit
        )

        coordinator.begin(sessionID: "s1")
        await waitUntil { source.isListening }
        source.emit("Open the Notes app", sequence: 1)
        source.emit("Open the Notes app and create a new note", sequence: 2)
        await waitUntil(timeout: 3) { executor.executed.count == 1 }
        XCTAssertEqual(executor.executed.count, 1)

        coordinator.end(sessionID: "s1")
        await waitUntil { audit.entries().contains { $0.toolName == "press_shortcut" } }
        XCTAssertEqual(executor.completed, [], "Escape must stop a step that hasn't finished.")
        XCTAssertEqual(audit.entries().first { $0.toolName == "press_shortcut" }?.outcome, "cancelled")
        XCTAssertEqual(launcher.launched, [apps[0]], "The app open had already reached macOS and is left alone.")
    }

    private func notesCoordinator(
        source: SpeculativeLaunchCoordinatorTests.FakeSource, launcher: SpeculativeLaunchCoordinatorTests.FakeLauncher,
        executor: FakeExecutor, audit: ActionAuditStore,
        runIsActive: @escaping @MainActor () -> Bool, carriedApp: @escaping @MainActor () -> String? = { nil },
        stabilityThreshold: Int = 1, ticks: AnyPublisher<EngineTick, Never> = Empty().eraseToAnyPublisher()
    ) async -> SpeculativeLaunchCoordinator {
        let directory = URL(fileURLWithPath: "/fixture/Applications")
        let apps = ["Notes", "Safari"].map { directory.appendingPathComponent("\($0).app") }
        let inventory = InstalledAppInventory(
            makeResolver: { AppResolver(directories: [directory], applicationsInDirectory: { _ in apps }) },
            bundleLookup: { _ in nil }, runningBundleURLs: { apps }
        )
        _ = await inventory.waitUntilReady(timeout: .seconds(5))
        return SpeculativeLaunchCoordinator(
            settings: .shared, source: source, inventory: inventory, launcher: launcher, executor: executor,
            awaitWindow: { _ in true }, carriedApp: carriedApp, runIsActive: runIsActive, audit: audit,
            stabilityThreshold: stabilityThreshold, ticks: ticks
        )
    }

    private func settle(_ coordinator: SpeculativeLaunchCoordinator, heard text: String) async {
        await waitUntil { coordinator.listening?.transcript == text }
        try? await Task.sleep(for: .milliseconds(100))
    }

    func testAnAppTheStepDetectorOpenedIsNotLaunchedAgainByTheLaunchDetector() async throws {
        let auditFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        defer { try? FileManager.default.removeItem(at: auditFile) }
        let source = SpeculativeLaunchCoordinatorTests.FakeSource()
        let launcher = SpeculativeLaunchCoordinatorTests.FakeLauncher()
        let executor = FakeExecutor()
        let coordinator = await notesCoordinator(source: source, launcher: launcher, executor: executor,
                                                 audit: ActionAuditStore(fileURL: auditFile),
                                                 runIsActive: { false }, stabilityThreshold: 2)
        defer { coordinator.end(sessionID: "s1") }

        coordinator.begin(sessionID: "s1")
        await waitUntil { source.isListening }
        source.emit("Open Notes", sequence: 1)
        await waitUntil { executor.executed.count == 1 }
        source.emit("Open Notes please", sequence: 2)
        await settle(coordinator, heard: "Open Notes please")

        XCTAssertEqual(executor.executed, [.openApp(name: "Notes")])
        XCTAssertEqual(launcher.launched, [], "The step detector already opened Notes; the launch detector's second sighting must not open it again.")
    }

    func testEarlyStepsWaitForTheActiveRunThenStartFromTheAppItLeft() async throws {
        let auditFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        defer { try? FileManager.default.removeItem(at: auditFile) }
        let source = SpeculativeLaunchCoordinatorTests.FakeSource()
        let launcher = SpeculativeLaunchCoordinatorTests.FakeLauncher()
        let executor = FakeExecutor()
        let busy = OSAllocatedUnfairLockBox(true)
        let carried = OSAllocatedUnfairLockBox<String?>(nil)
        let coordinator = await notesCoordinator(source: source, launcher: launcher, executor: executor,
                                                 audit: ActionAuditStore(fileURL: auditFile),
                                                 runIsActive: { busy.value }, carriedApp: { carried.value })
        defer { coordinator.end(sessionID: "s1") }

        coordinator.begin(sessionID: "s1")
        await waitUntil { source.isListening }
        source.emit("Create a new note and", sequence: 1)
        await settle(coordinator, heard: "Create a new note and")
        XCTAssertEqual(executor.executed, [], "The previous command is still typing; ⌘N would land under it.")

        carried.mutate { $0 = "Notes" }
        busy.mutate { $0 = false }
        source.emit("Create a new note and type", sequence: 2)
        await waitUntil { executor.executed.count == 1 }
        let commandN = try XCTUnwrap(KeyboardShortcut(keys: ["cmd", "n"]))
        XCTAssertEqual(executor.executed, [.pressShortcut(app: "Notes", shortcut: commandN)], "Detection restarts in the app the run left open.")
        XCTAssertEqual(launcher.launched, [])
    }

    func testARunStartingMidUtteranceStopsEarlyStepsAndLeavesTheRestForTheCommand() async throws {
        let auditFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        defer { try? FileManager.default.removeItem(at: auditFile) }
        let audit = ActionAuditStore(fileURL: auditFile)
        let source = SpeculativeLaunchCoordinatorTests.FakeSource()
        let launcher = SpeculativeLaunchCoordinatorTests.FakeLauncher()
        let executor = FakeExecutor()
        executor.delay = .seconds(30)
        let busy = OSAllocatedUnfairLockBox(false)
        let coordinator = await notesCoordinator(source: source, launcher: launcher, executor: executor, audit: audit,
                                                 runIsActive: { busy.value })
        defer { coordinator.end(sessionID: "s1") }

        coordinator.begin(sessionID: "s1")
        await waitUntil { source.isListening }
        source.emit("Open the Notes app", sequence: 1)
        source.emit("Open the Notes app and create a new note and", sequence: 2)
        await waitUntil { executor.executed.count == 1 }

        busy.mutate { $0 = true }
        source.emit("Open the Notes app and create a new note and open Safari and", sequence: 3)
        await waitUntil { audit.entries().contains { $0.toolName == "press_shortcut" } }
        busy.mutate { $0 = false }
        source.emit("Open the Notes app and create a new note and open Safari and type hello and", sequence: 4)
        await settle(coordinator, heard: "Open the Notes app and create a new note and open Safari and type hello and")

        XCTAssertEqual(executor.executed.count, 1, "Nothing more runs early once another run has started.")
        XCTAssertEqual(executor.completed, [], "The ⌘N still waiting is stopped.")
        let handoff = try XCTUnwrap(coordinator.takeHandoff(sessionID: "s1"))
        var failures: [String?] = []
        for run in handoff.steps { failures.append(await run.result().failure) }
        XCTAssertEqual(failures, ["cancelled"], "The final command redoes what was stopped.")
    }

    func testTypingRunsOnTheFirstSufficientTickOfTheActiveSessionOnly() async throws {
        let auditFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        defer { try? FileManager.default.removeItem(at: auditFile) }
        let source = SpeculativeLaunchCoordinatorTests.FakeSource()
        let launcher = SpeculativeLaunchCoordinatorTests.FakeLauncher()
        let executor = FakeExecutor()
        let ticks = PassthroughSubject<EngineTick, Never>()
        let coordinator = await notesCoordinator(source: source, launcher: launcher, executor: executor,
                                                 audit: ActionAuditStore(fileURL: auditFile), runIsActive: { false },
                                                 ticks: ticks.eraseToAnyPublisher())
        defer { coordinator.end(sessionID: "s1") }
        func tick(_ session: String, silence: Int) -> EngineTick {
            EngineTick(sessionID: session, audio: .seconds(4), trailingSilence: .milliseconds(silence))
        }

        coordinator.begin(sessionID: "s1")
        await waitUntil { source.isListening }
        source.emit("Open the Notes app", sequence: 1)
        source.emit("Open the Notes app and let's make the title say hello.", sequence: 2)
        await settle(coordinator, heard: "Open the Notes app and let's make the title say hello.")
        XCTAssertEqual(executor.executed, [], "Typing waits for measured silence, however the sentence ends.")

        ticks.send(tick("another-take", silence: 2_000))
        await settle(coordinator, heard: "Open the Notes app and let's make the title say hello.")
        XCTAssertEqual(executor.executed, [], "Another take's silence says nothing about this one.")

        ticks.send(tick("s1", silence: 299))
        await settle(coordinator, heard: "Open the Notes app and let's make the title say hello.")
        XCTAssertEqual(executor.executed, [], "299 ms is not enough.")

        ticks.send(tick("s1", silence: 300))
        await waitUntil { executor.executed.count == 1 }
        XCTAssertEqual(executor.executed, [.typeText(app: "Notes", text: "hello")])
        let handoff = try XCTUnwrap(coordinator.takeHandoff(sessionID: "s1"))
        XCTAssertEqual(handoff.steps.map(\.step.index), [1])
        let result = await try XCTUnwrap(handoff.steps.first).result()
        XCTAssertTrue(result.succeeded)
    }

    func testAskBeforeEveryToolOpensNothingEarly() async {
        AppSettings.shared.actionApprovalPolicy = .alwaysAsk
        let auditFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        defer { try? FileManager.default.removeItem(at: auditFile) }
        let source = SpeculativeLaunchCoordinatorTests.FakeSource()
        let launcher = SpeculativeLaunchCoordinatorTests.FakeLauncher()
        let executor = FakeExecutor()
        let coordinator = await notesCoordinator(source: source, launcher: launcher, executor: executor,
                                                 audit: ActionAuditStore(fileURL: auditFile), runIsActive: { false })
        defer { coordinator.end(sessionID: "s1") }

        coordinator.begin(sessionID: "s1")
        await waitUntil { source.isListening }
        source.emit("Open the Notes app", sequence: 1)
        source.emit("Open the Notes app and go to example.com and", sequence: 2)
        await settle(coordinator, heard: "Open the Notes app and go to example.com and")

        XCTAssertEqual(launcher.launched, [])
        XCTAssertEqual(executor.executed, [])
        XCTAssertNil(coordinator.takeHandoff(sessionID: "s1"))
    }

    func testCancellingTheRunStopsAdoptedAndQueuedEarlySteps() async throws {
        func pendingStep(_ index: Int) -> SpeculativeStepRun {
            let step = SpeculativeStep(index: index, clause: "type hello", action: .typeText(app: "Notes", text: "hello"), sequence: 2)
            return SpeculativeStepRun(step: step, outcome: Task {
                do {
                    try await Task.sleep(for: .seconds(30))
                    return .success("Typed “hello” in Notes (pid 77).")
                } catch {
                    return .failure(error)
                }
            })
        }
        let router = AgentSessionControllerTests.FakeRouter(specs: [])
        let controller = AgentSessionController(
            settings: .shared, router: router, plannerFactory: { nil },
            resolveApp: { _ in nil }, isAppRunning: { _ in true }, frontmostApp: { nil }
        )
        let adopted = pendingStep(0)
        let queued = pendingStep(1)
        controller.handleCommand("type hello", handoff: SpeculativeHandoff(steps: [adopted]))
        controller.handleCommand("type hello again", handoff: SpeculativeHandoff(steps: [queued]))
        XCTAssertEqual(controller.queuedCommands.count, 1)

        controller.cancel()
        let adoptedResult = await adopted.result()
        let queuedResult = await queued.result()
        XCTAssertEqual(adoptedResult.failure, "cancelled")
        XCTAssertEqual(queuedResult.failure, "cancelled")
        XCTAssertEqual(router.executed, [])
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
