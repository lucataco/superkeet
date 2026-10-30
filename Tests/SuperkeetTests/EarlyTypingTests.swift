import XCTest
@testable import Superkeet

final class EarlyTypingReconciliationTests: XCTestCase {
    private func typing(_ text: String, in app: String = "Notes") -> EarlyTypingReconciliation.Typing {
        .init(app: app, text: text)
    }

    func testTheSameTextIsAlreadyTypedWhateverItsCase() {
        XCTAssertEqual(EarlyTypingReconciliation.reconcile(early: typing("hello"), final: typing("hello")), .alreadyTyped)
        XCTAssertEqual(EarlyTypingReconciliation.reconcile(early: typing("Hello"), final: typing("hello")), .alreadyTyped)
    }

    func testAnExtensionTypesOnlyTheSuffix() {
        XCTAssertEqual(EarlyTypingReconciliation.reconcile(early: typing("hello"), final: typing("hello world")), .typeRemainder(" world"))
        XCTAssertEqual(EarlyTypingReconciliation.reconcile(early: typing("hello"), final: typing("Hello, world")), .typeRemainder(", world"))
        XCTAssertEqual(EarlyTypingReconciliation.reconcile(early: typing("hello"), final: typing("hello!")), .typeRemainder("!"))
    }

    func testAnyOtherDifferenceTypesNothing() {
        XCTAssertEqual(EarlyTypingReconciliation.reconcile(early: typing("hello"), final: typing("goodbye")), .keepTyped)
        XCTAssertEqual(EarlyTypingReconciliation.reconcile(early: typing("hello world"), final: typing("hello")), .keepTyped, "Never delete what was typed.")
        XCTAssertEqual(EarlyTypingReconciliation.reconcile(early: typing("hello"), final: typing("say hello")), .keepTyped)
        XCTAssertEqual(EarlyTypingReconciliation.reconcile(early: typing("hello"), final: typing("hello world", in: "TextEdit")), .keepTyped, "The text went to another app.")
    }

    func testTheHUDLineSaysWhatWasTypedEarly() {
        XCTAssertEqual(EarlyTypingReconciliation.keptLine(typed: "hello", final: "help"), "Typed “hello” early, not “help”")
        let long = String(repeating: "word ", count: 30)
        XCTAssertTrue(EarlyTypingReconciliation.keptLine(typed: long, final: "help").contains("…"), "A long text is clipped like every other line.")
    }
}

@MainActor
final class EarlyTypingHandoffTests: XCTestCase {
    private let notes = URL(fileURLWithPath: "/fixture/Applications/Notes.app")

    private struct Outcome {
        let executedTexts: [String]
        let controller: AgentSessionController
    }

    private func finalCommand(_ command: String, typedEarly: String) async throws -> Outcome {
        let step = SpeculativeStep(index: 0, clause: "type \(typedEarly) in Notes", action: .typeText(app: "Notes", text: typedEarly), sequence: 2)
        let early = SpeculativeStepRun(step: step, outcome: Task { .success("Typed “\(typedEarly)” in Notes (pid 77).") })
        let router = AgentSessionControllerTests.FakeRouter(specs: [])
        router.preparationFailure = ActionExecutionError.noMCPServersEnabled
        router.outputs["type_text"] = "Typed in Notes (pid 77)."
        let notes = self.notes
        let controller = AgentSessionController(
            settings: .shared, router: router, plannerFactory: { nil },
            resolveApp: { AppResolver.normalizedName($0).contains("notes") ? notes : nil }, isAppRunning: { $0 == notes },
            frontmostApp: { nil }
        )
        controller.handleCommand(command, handoff: SpeculativeHandoff(steps: [early]))
        let deadline = Date().addingTimeInterval(5)
        while controller.phase.isActive && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        if case .finished = controller.phase {} else { XCTFail("Expected success, got \(controller.phase)") }
        let texts = try router.arguments.map { json -> String in
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            return try XCTUnwrap(object["text"] as? String)
        }
        return Outcome(executedTexts: texts, controller: controller)
    }

    func testTheSameTextIsNotTypedAgain() async throws {
        let outcome = try await finalCommand("type hello in Notes.", typedEarly: "hello")
        XCTAssertEqual(outcome.executedTexts, [])
        XCTAssertTrue(outcome.controller.activityLog.contains { $0.hasPrefix("Already done: Typed") }, "\(outcome.controller.activityLog)")
    }

    func testAnExtensionTypesOnlyWhatWasAdded() async throws {
        let outcome = try await finalCommand("type hello world in Notes.", typedEarly: "hello")
        XCTAssertEqual(outcome.executedTexts, [" world"])
    }

    func testADifferentTextTypesNothingAndSaysWhatWasTypedEarly() async throws {
        let outcome = try await finalCommand("type goodbye in Notes.", typedEarly: "hello")
        XCTAssertEqual(outcome.executedTexts, [])
        XCTAssertEqual(outcome.controller.checklist.lines.map(\.title), ["Typed “hello” early, not “goodbye”"], "The early line is retitled, not joined by a second.")
        XCTAssertEqual(outcome.controller.checklist.lines.map(\.status), [.done])
    }

    func testAnExtensionInTheLastClauseOfACompoundCommandTypesOnlyTheSuffix() async throws {
        let commandN = try XCTUnwrap(KeyboardShortcut(keys: ["cmd", "n"]))
        let commit = SpeculativeCommit(action: .launch(SpeculativeApp(spokenName: "notes", url: notes)), clause: "open notes", sequence: 2, reason: .clauseBoundary)
        let launch = SpeculativeLaunch(commit: commit, disagreement: false, outcome: Task {
            .success(NativeLaunchedApp(name: "Notes", bundleIdentifier: "com.apple.Notes", processIdentifier: 77, windowReady: true))
        })
        let newNote = SpeculativeStep(index: 1, clause: "create a new note", action: .pressShortcut(app: "Notes", shortcut: commandN), sequence: 3)
        let typed = SpeculativeStep(index: 2, clause: "make the title say hello", action: .typeText(app: "Notes", text: "hello"), sequence: 6)
        let router = AgentSessionControllerTests.FakeRouter(specs: [])
        router.preparationFailure = ActionExecutionError.noMCPServersEnabled
        router.outputs["type_text"] = "Typed in Notes (pid 77)."
        let notes = self.notes
        let controller = AgentSessionController(
            settings: .shared, router: router, plannerFactory: { nil },
            resolveApp: { AppResolver.normalizedName($0).contains("notes") ? notes : nil }, isAppRunning: { $0 == notes },
            frontmostApp: { nil }
        )
        controller.handleCommand(
            "open the notes app and create a new note and make the title say hello world",
            handoff: SpeculativeHandoff(launch: launch, steps: [
                SpeculativeStepRun(step: newNote, outcome: Task { .success("Pressed ⌘N in Notes (pid 77).") }),
                SpeculativeStepRun(step: typed, outcome: Task { .success("Typed “hello” in Notes (pid 77).") })
            ])
        )
        let deadline = Date().addingTimeInterval(5)
        while controller.phase.isActive && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }

        XCTAssertEqual(router.executed, ["type_text"], "Open and ⌘N ran early; only the extension of the typing is left.")
        let arguments = try XCTUnwrap(router.arguments.first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any])
        XCTAssertEqual(object["text"] as? String, " world")
        if case .finished = controller.phase {} else { XCTFail("Expected success, got \(controller.phase)") }
    }

    func testAFailedEarlyTypingStepIsTypedInFull() async throws {
        let step = SpeculativeStep(index: 0, clause: "type hello in Notes", action: .typeText(app: "Notes", text: "hello"), sequence: 2)
        let failed = SpeculativeStepRun(step: step, outcome: Task { .failure(NativeOpenActionError.appNotRunning("Notes")) })
        let router = AgentSessionControllerTests.FakeRouter(specs: [])
        router.outputs["type_text"] = "Typed in Notes (pid 77)."
        let notes = self.notes
        let controller = AgentSessionController(
            settings: .shared, router: router, plannerFactory: { nil },
            resolveApp: { AppResolver.normalizedName($0).contains("notes") ? notes : nil }, isAppRunning: { $0 == notes },
            frontmostApp: { nil }
        )
        controller.handleCommand("type hello world in Notes.", handoff: SpeculativeHandoff(steps: [failed]))
        let deadline = Date().addingTimeInterval(5)
        while controller.phase.isActive && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(router.executed, ["type_text"])
        XCTAssertTrue(router.arguments.first?.contains("hello world") ?? false, "Nothing was typed early, so all of it is typed now.")
    }
}
