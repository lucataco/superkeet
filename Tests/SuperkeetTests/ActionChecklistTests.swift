import XCTest
@testable import Superkeet

final class ActionChecklistTests: XCTestCase {
    private func spec(_ name: String, title: String? = nil) -> ActionToolSpec {
        ActionToolSpec(descriptor: MCPToolDescriptor(serverID: UUID(), serverName: "fixture", name: name, title: title,
                                                     description: nil, risk: .mutating, inputSchemaJSON: "{}"))
    }

    private func launch(launched: Bool, activation: Bool = false, disagreement: Bool = false) -> SpeculativeLaunchResult {
        let app = SpeculativeApp(spokenName: "notes", url: URL(fileURLWithPath: "/Applications/Notes.app"))
        let commit = SpeculativeCommit(action: activation ? .activate(app) : .launch(app), clause: "open notes", sequence: 1, reason: .finalized)
        return SpeculativeLaunchResult(
            commit: commit,
            launched: launched ? NativeLaunchedApp(name: "Notes", bundleIdentifier: nil, processIdentifier: 1, windowReady: true) : nil,
            failure: launched ? nil : "Launch refused",
            disagreement: disagreement
        )
    }

    func testToolRowsChangeStatusInPlaceRatherThanAppending() {
        var checklist = ActionChecklist()
        let open = spec("open_app", title: "Open App")
        checklist.apply(.toolStarted(open))
        XCTAssertEqual(checklist.items.map(\.status), [.running])
        XCTAssertEqual(checklist.items.first?.title, "Open App")
        checklist.apply(.toolFinished(open, "Opened Notes."))
        XCTAssertEqual(checklist.items.count, 1, "Finishing updates the running row instead of adding one.")
        XCTAssertEqual(checklist.items.first?.status, .done)

        checklist.apply(.toolStarted(spec("click")))
        checklist.apply(.toolFailed(spec("click"), "Timed out"))
        XCTAssertEqual(checklist.items.last?.status, .failed)
        XCTAssertEqual(checklist.items.last?.detail, "Timed out")

        checklist.apply(.toolStarted(spec("type_text")))
        checklist.apply(.toolDenied(spec("type_text")))
        XCTAssertEqual(checklist.items.last?.status, .denied)
        XCTAssertEqual(checklist.items.count, 3)
    }

    func testReusedAndUnmatchedOutcomesAppendTheirOwnRows() {
        var checklist = ActionChecklist()
        checklist.apply(.toolReused(spec("open_app", title: "Open App")))
        XCTAssertEqual(checklist.items.map(\.status), [.reused])
        XCTAssertEqual(checklist.items.first?.detail, "Already done; result reused")
        checklist.apply(.toolFinished(spec("echo"), "x"))
        XCTAssertEqual(checklist.items.map(\.status), [.reused, .done])
        XCTAssertEqual(checklist.items.last?.title, "echo")
    }

    func testStepsWrapTheirToolsAndSettleOnCompletion() {
        var checklist = ActionChecklist()
        checklist.addStep(number: 1, total: 2, text: "open the notes app")
        checklist.apply(.toolStarted(spec("open_app")))
        checklist.apply(.toolFinished(spec("open_app"), ""))
        checklist.completeStep()
        checklist.addStep(number: 2, total: 2, text: "create a new note")
        checklist.completeStep(skippedBecause: "Already done while you were speaking")

        XCTAssertEqual(checklist.items.map(\.status), [.done, .done, .skipped])
        XCTAssertEqual(checklist.items[0].kind, .step(number: 1, total: 2))
        XCTAssertEqual(checklist.items[2].detail, "Already done while you were speaking")
    }

    func testSpeculativeRowsComeFirstAndDescribeTheOutcome() {
        var checklist = ActionChecklist()
        checklist.addSpeculative(launch(launched: true))
        XCTAssertEqual(checklist.items.map(\.title), ["Opened Notes while you were speaking"])
        XCTAssertEqual(checklist.items.first?.kind, .speculative)
        XCTAssertEqual(checklist.items.first?.status, .done)

        var activated = ActionChecklist()
        activated.addSpeculative(launch(launched: true, activation: true, disagreement: true))
        XCTAssertEqual(activated.items.map(\.title), ["Switched to Notes while you were speaking",
                                                      "Later speech named a different app; the final command decides"])
        XCTAssertEqual(activated.items.last?.status, .info)

        var failed = ActionChecklist()
        failed.addSpeculative(launch(launched: false))
        XCTAssertEqual(failed.items.first?.status, .failed)
        XCTAssertEqual(failed.items.first?.title, "Couldn't open Notes early")
        XCTAssertEqual(failed.items.first?.detail, "Launch refused")
    }

    func testFinishSettlesAnythingStillRunning() {
        var checklist = ActionChecklist()
        checklist.addStep(number: 1, total: 1, text: "look")
        checklist.apply(.toolStarted(spec("get_window_state")))
        checklist.finish(succeeded: false)
        XCTAssertEqual(checklist.items.map(\.status), [.failed, .failed])

        var ok = ActionChecklist()
        ok.apply(.toolStarted(spec("echo")))
        ok.finish(succeeded: true)
        XCTAssertEqual(ok.items.map(\.status), [.done])
    }

    func testVisibleItemsKeepTheCurrentStepWhenFolding() {
        var checklist = ActionChecklist()
        checklist.addStep(number: 1, total: 2, text: "first")
        for index in 0..<8 { checklist.apply(.toolReused(spec("tool\(index)"))) }
        checklist.completeStep()
        checklist.addStep(number: 2, total: 2, text: "second")
        checklist.apply(.toolReused(spec("last")))

        let all = checklist.visibleItems(limit: 100)
        XCTAssertEqual(all.hidden, 0)
        XCTAssertEqual(all.items.count, checklist.items.count)

        let folded = checklist.visibleItems(limit: 3)
        XCTAssertEqual(folded.items.count, 3)
        XCTAssertEqual(folded.hidden, checklist.items.count - 3)
        XCTAssertEqual(folded.items.map(\.title), ["tool7", "second", "last"], "The newest rows are shown in order.")

        let tight = checklist.visibleItems(limit: 1)
        XCTAssertEqual(tight.items.map(\.title), ["second"], "When the current step would fold away, it replaces the oldest visible row.")
        XCTAssertEqual(tight.hidden, checklist.items.count - 1)
    }

    func testNotesAreInformational() {
        var checklist = ActionChecklist()
        checklist.addNote("Using ⌘N to create a new note in Notes")
        XCTAssertEqual(checklist.items.first?.kind, .note)
        XCTAssertEqual(checklist.items.first?.status, .info)
        checklist.apply(.planning)
        checklist.apply(.message("thinking"))
        XCTAssertEqual(checklist.items.count, 1, "Planning and streamed text do not add rows.")
    }
}
