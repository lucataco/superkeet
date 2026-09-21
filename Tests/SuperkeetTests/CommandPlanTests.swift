import XCTest
@testable import Superkeet

final class CommandPlanTests: XCTestCase {
    private let notes = URL(fileURLWithPath: "/fixture/Applications/Notes.app")
    private let pages = URL(fileURLWithPath: "/fixture/Applications/Pages.app")

    private func resolve(_ name: String) -> URL? {
        let apps = [notes, pages]
        return AppResolver(directories: [URL(fileURLWithPath: "/fixture/Applications")], applicationsInDirectory: { _ in apps }).resolve(name)
    }

    private func launch(_ url: URL, launched: Bool = true) -> SpeculativeLaunchResult {
        let app = SpeculativeApp(spokenName: url.deletingPathExtension().lastPathComponent.lowercased(), url: url)
        let commit = SpeculativeCommit(action: .launch(app), clause: "open \(app.spokenName)", sequence: 2, reason: .stable(count: 2))
        let launchedApp = launched ? NativeLaunchedApp(name: app.name, bundleIdentifier: nil, processIdentifier: 42, windowReady: true) : nil
        return SpeculativeLaunchResult(commit: commit, launched: launchedApp, failure: launched ? nil : "refused", disagreement: false)
    }

    func testCompoundCommandBecomesOrderedClassifiedClauses() {
        let plan = CommandDecomposer.decompose("  Open the Notes app and create a new note. ")
        XCTAssertEqual(plan.command, "Open the Notes app and create a new note.")
        XCTAssertTrue(plan.isCompound)
        XCTAssertEqual(plan.clauses.map(\.text), ["Open the Notes app", "create a new note"])
        XCTAssertEqual(plan.clauses.map(\.index), [0, 1])
        XCTAssertEqual(plan.clauses[0].intent.action, .openApp)
        XCTAssertEqual(plan.clauses[1].intent.action, .other)
        XCTAssertEqual(plan.clauses[1].focusTerms, ["create", "new", "note"])
    }

    func testSingleClauseKeepsTheWholeCommandIntent() {
        let plan = CommandDecomposer.decompose("open Helium and go to youtube.com")
        XCTAssertEqual(plan.clauses.map(\.text), ["open Helium", "go to youtube.com"])

        let single = CommandDecomposer.decompose("Search for cats")
        XCTAssertFalse(single.isCompound)
        XCTAssertEqual(single.clauses.first?.intent.action, .webSearch)
        XCTAssertEqual(single.clauses.first?.intent, HeuristicIntentExtractor.intent(for: "Search for cats"))
    }

    func testActiveTabCommandsAreNeverSplit() {
        let plan = CommandDecomposer.decompose("In the current Chrome tab, go to youtube.com and find the DNS records")
        XCTAssertFalse(plan.isCompound)
        XCTAssertEqual(plan.clauses.first?.intent.scope, .activeTab)
    }

    func testQuotedTextIsNotSplit() {
        XCTAssertEqual(CommandClauses.split(#"type "hello, and goodbye" into Title in Notes"#), [#"type "hello, and goodbye" into Title in Notes"#])
        XCTAssertEqual(CommandClauses.split("type “one, two” into Body and click Save"), ["type “one, two” into Body", "click Save"])
        XCTAssertEqual(CommandClauses.split("say 'wait, then go' and open Notes"), ["say 'wait, then go'", "open Notes"])
        XCTAssertEqual(CommandClauses.split(#"type "x" into Title."#), [#"type "x" into Title"#], "Only sentence punctuation is trimmed, never quotes.")
    }

    func testEmptyCommandStillYieldsOneClause() {
        let plan = CommandDecomposer.decompose("   ")
        XCTAssertEqual(plan.clauses.count, 1)
        XCTAssertEqual(plan.clauses.first?.text, "")
    }

    func testOpenClauseIsSatisfiedByMatchingLaunch() {
        let plan = CommandDecomposer.decompose("open the notes app and create a new note")
        XCTAssertTrue(CommandDecomposer.clause(plan.clauses[0], isSatisfiedBy: launch(notes), resolveApp: resolve))
        XCTAssertFalse(CommandDecomposer.clause(plan.clauses[1], isSatisfiedBy: launch(notes), resolveApp: resolve))
        XCTAssertFalse(CommandDecomposer.clause(plan.clauses[0], isSatisfiedBy: launch(pages), resolveApp: resolve), "A different app was opened.")
        XCTAssertFalse(CommandDecomposer.clause(plan.clauses[0], isSatisfiedBy: launch(notes, launched: false), resolveApp: resolve), "A failed launch satisfies nothing.")
    }

    func testSwitchClauseAndAliasesMatchTheLaunchedBundle() {
        let switchPlan = CommandDecomposer.decompose("switch to Notes then create a new note")
        XCTAssertTrue(CommandDecomposer.clause(switchPlan.clauses[0], isSatisfiedBy: launch(notes), resolveApp: resolve))
        let filler = CommandDecomposer.decompose("please open up notes and save it")
        XCTAssertTrue(CommandDecomposer.clause(filler.clauses[0], isSatisfiedBy: launch(notes), resolveApp: resolve))
    }

    func testURLAndCombinedClausesAreNotSatisfiedByAnAppLaunch() {
        let url = CommandDecomposer.decompose("open youtube.com and search")
        XCTAssertFalse(CommandDecomposer.clause(url.clauses[0], isSatisfiedBy: launch(notes), resolveApp: resolve))
        let whole = CommandClause(index: 0, text: "open Notes and create a note", intent: HeuristicIntentExtractor.intent(for: "open Notes and create a note"))
        XCTAssertFalse(CommandDecomposer.clause(whole, isSatisfiedBy: launch(notes), resolveApp: resolve), "An unsplit compound clause still has work left.")
    }

    func testContextInstructionsDescribeProgressAndOpenApps() {
        var context = ActionPlanContext(command: "open the notes app and create a new note")
        XCTAssertTrue(context.isEmpty)
        XCTAssertEqual(context.instructions(for: "anything"), "")

        context.stepCount = 2
        context.stepNumber = 2
        context.completed.append(.init(clause: "open the notes app", summary: "Opened Notes (pid 42). Its window is on screen."))
        context.recordOpened(NativeLaunchedApp(name: "Notes", bundleIdentifier: "com.apple.Notes", processIdentifier: 42, windowReady: true))
        XCTAssertFalse(context.isEmpty)
        XCTAssertTrue(context.isFinalStep)
        let text = context.instructions(for: "create a new note")
        XCTAssertTrue(text.contains("step 2 only: \"create a new note\""), text)
        XCTAssertTrue(text.contains("1. \"open the notes app\" — Opened Notes (pid 42). Its window is on screen."), text)
        XCTAssertTrue(text.contains("Notes is already open (pid 42; its window is on screen). Do not open it again"), text)
        XCTAssertTrue(text.contains("it refers to Notes"), text)
        XCTAssertFalse(text.contains("Later steps follow"), "The final step has nothing after it.")

        context.stepNumber = 1
        context.stepCount = 3
        XCTAssertTrue(context.instructions(for: "x").contains("Later steps follow; do not carry them out now."))
    }

    func testRecordOpenedReplacesTheSameProcessAndKeepsTheLatestCurrent() {
        var context = ActionPlanContext(command: "c")
        let first = NativeLaunchedApp(name: "Notes", bundleIdentifier: nil, processIdentifier: 1, windowReady: false)
        context.recordOpened(first)
        context.recordOpened(NativeLaunchedApp(name: "Pages", bundleIdentifier: nil, processIdentifier: 2, windowReady: true))
        context.recordOpened(NativeLaunchedApp(name: "Notes", bundleIdentifier: nil, processIdentifier: 1, windowReady: true))
        XCTAssertEqual(context.openedApps.map(\.name), ["Pages", "Notes"])
        XCTAssertEqual(context.currentApp?.name, "Notes")
        XCTAssertEqual(context.currentApp?.windowReady, true)
        XCTAssertTrue(context.instructions(for: "x").contains("its window is on screen"))
    }

    func testMarkingAWindowReadyKeepsTheCurrentAppOrder() {
        var context = ActionPlanContext(command: "c")
        context.recordOpened(NativeLaunchedApp(name: "Chrome", bundleIdentifier: nil, processIdentifier: 1, windowReady: false))
        context.recordOpened(NativeLaunchedApp(name: "Notes", bundleIdentifier: nil, processIdentifier: 2, windowReady: true))
        context.markWindowReady(processIdentifier: 1)
        XCTAssertEqual(context.openedApps.map(\.name), ["Chrome", "Notes"])
        XCTAssertEqual(context.openedApps.map(\.windowReady), [true, true])
        XCTAssertEqual(context.currentApp?.name, "Notes")
    }

    func testLongStepSummariesAreClippedInInstructions() {
        var context = ActionPlanContext(command: "c")
        context.stepCount = 2
        context.stepNumber = 2
        context.completed.append(.init(clause: "look", summary: String(repeating: "x", count: 500)))
        let text = context.instructions(for: "next")
        XCTAssertTrue(text.contains("characters omitted"))
        XCTAssertLessThan(text.count, 400)
    }

    func testLaunchSummaryRoundTrips() throws {
        for app in [
            NativeLaunchedApp(name: "Notes", bundleIdentifier: "com.apple.Notes", processIdentifier: 1234, windowReady: true),
            NativeLaunchedApp(name: "Visual Studio Code", bundleIdentifier: nil, processIdentifier: 7, windowReady: false),
            NativeLaunchedApp(name: "Weird (Beta)", bundleIdentifier: "", processIdentifier: 99, windowReady: true)
        ] {
            let parsed = try XCTUnwrap(NativeLaunchedApp(summary: app.summary), app.summary)
            XCTAssertEqual(parsed.name, app.name)
            XCTAssertEqual(parsed.processIdentifier, app.processIdentifier)
            XCTAssertEqual(parsed.windowReady, app.windowReady)
            XCTAssertEqual(parsed.bundleIdentifier, app.bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 })
        }
        for text in ["Opened Notes.", "tool-output", "Opened Notes (pid x). Its window is on screen.", "Opened Notes (pid 1). Something else."] {
            XCTAssertNil(NativeLaunchedApp(summary: text), text)
        }
    }
}
