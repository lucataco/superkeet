import XCTest
@testable import Superkeet

final class ActionChecklistTests: XCTestCase {
    private func spec(_ name: String, title: String? = nil) -> ActionToolSpec {
        ActionToolSpec(descriptor: MCPToolDescriptor(serverID: UUID(), serverName: "fixture", name: name, title: title,
                                                     description: nil, risk: .mutating, inputSchemaJSON: "{}"))
    }

    func testToolCallsNeverAddLinesOfTheirOwn() {
        var checklist = ActionChecklist()
        checklist.setOpenLine("Summarize the page")
        checklist.apply(.toolStarted(spec("list_windows", title: "List Windows")))
        checklist.apply(.toolFinished(spec("list_windows", title: "List Windows"), "[]"))
        checklist.apply(.toolReused(spec("list_windows", title: "List Windows")))
        checklist.settleOpenLine()
        checklist.addReply("The page is about cats.")

        XCTAssertEqual(checklist.lines, [ActionLine(status: .done, title: "Summarize the page")])
        XCTAssertEqual(checklist.outcomeText(message: "ignored", succeeded: true), "The page is about cats.")
    }

    func testAFailedToolDoesNotFailTheLineUntilTheCommandDoes() {
        var checklist = ActionChecklist()
        checklist.setOpenLine("Summarize the page")
        checklist.apply(.toolStarted(spec("get_browser_state")))
        checklist.apply(.toolFailed(spec("get_browser_state"), "Timed out."))
        XCTAssertEqual(checklist.lines, [ActionLine(status: .running, title: "Summarize the page")])

        checklist.finish(.failed(message: "Couldn't read the page. No browser tools are enabled. browser_requires_setup"))
        XCTAssertEqual(checklist.lines, [ActionLine(status: .failed(reason: "Couldn't read the page."), title: "Summarize the page")])
        XCTAssertEqual(checklist.lines.first?.reason, "Couldn't read the page.")
    }

    func testAToolThatFailedBeforeThePlannerRecoveredLeavesTheLineDone() {
        var checklist = ActionChecklist()
        checklist.setOpenLine("Summarize the page")
        checklist.apply(.toolFailed(spec("first"), "Timed out."))
        checklist.apply(.toolStarted(spec("second")))
        checklist.apply(.toolFinished(spec("second"), "ok"))
        checklist.settleOpenLine()
        checklist.addReply("The page is about cats.")
        checklist.finish(.succeeded)

        XCTAssertEqual(checklist.lines, [ActionLine(status: .done, title: "Summarize the page")])
        XCTAssertNil(checklist.lines.first?.reason)
    }

    func testAFailureWithNothingToSayHasNoReason() {
        var checklist = ActionChecklist()
        checklist.setOpenLine("Do the thing")
        checklist.finish(.failed(message: "browser_requires_setup"))
        XCTAssertEqual(checklist.lines, [ActionLine(status: .failed(reason: nil), title: "Do the thing")])
        XCTAssertNil(checklist.lines.first?.reason)
    }

    func testCancelledFailsRunningLines() {
        var checklist = ActionChecklist()
        checklist.setOpenLine("Do the thing")
        checklist.finish(.cancelled)
        XCTAssertTrue(checklist.hasFailedLine)
    }

    func testADeniedToolMarksTheLineDenied() {
        var checklist = ActionChecklist()
        checklist.setOpenLine("Press save")
        checklist.apply(.toolStarted(spec("press_shortcut")))
        checklist.apply(.toolDenied(spec("press_shortcut")))
        checklist.finish(.failed(message: "The action was not approved."))

        XCTAssertEqual(checklist.lines, [ActionLine(status: .denied, title: "Press save")])
        XCTAssertEqual(checklist.lines.first?.reason, "Not approved")
    }

    func testBeginningAgainReplacesTheUnfinishedAttemptInsteadOfListingBoth() {
        var checklist = ActionChecklist()
        checklist.setOpenLine("Open Helium")
        checklist.apply(.toolFailed(spec("open_app"), "Could not find an installed app named 'Helium'."))
        checklist.setOpenLine("Open helium and read it")
        XCTAssertEqual(checklist.lines, [ActionLine(status: .running, title: "Open helium and read it")])

        checklist.settleOpenLine()
        checklist.setOpenLine("Next thing")
        XCTAssertEqual(checklist.lines.map(\.title), ["Open helium and read it", "Next thing"], "A completed line is never replaced.")
    }

    func testEarlyWorkIsOneDoneLineEach() {
        var checklist = ActionChecklist()
        checklist.addDone("Opened TextEdit")
        checklist.addDone("New document")
        checklist.settleOpenLine(title: "ignored")
        XCTAssertEqual(checklist.lines.map(\.title), ["Opened TextEdit", "New document"], "With no line open, completing changes nothing.")
        XCTAssertEqual(Set(checklist.lines.map(\.status)), [.done])
    }

    func testFinishSettlesWhatIsStillRunning() {
        var failed = ActionChecklist()
        failed.setOpenLine("Look around")
        failed.finish(.failed(message: "Timed out."))
        XCTAssertEqual(failed.lines.map(\.status), [.failed(reason: "Timed out.")])

        var ok = ActionChecklist()
        ok.setOpenLine("Look around")
        ok.finish(.succeeded)
        XCTAssertEqual(ok.lines.map(\.status), [.done])
    }

    func testOutcomeTextDropsRawMessagesTheLinesAlreadyExplain() {
        var done = ActionChecklist()
        done.addDone("Opened TextEdit")
        XCTAssertNil(done.outcomeText(message: "Opened TextEdit (pid 4039, com.apple.TextEdit). No window has appeared yet.", succeeded: true))

        var explained = ActionChecklist()
        explained.setOpenLine("Summarize the page")
        explained.finish(.failed(message: "No browser tools are enabled."))
        XCTAssertNil(explained.outcomeText(message: "No browser tools are enabled.", succeeded: false))

        var unexplained = ActionChecklist()
        unexplained.setOpenLine("Do the thing")
        unexplained.finish(.failed(message: "browser_requires_setup"))
        XCTAssertEqual(unexplained.outcomeText(message: "No MCP servers are enabled. Enable a server in Settings.", succeeded: false),
                       "No MCP servers are enabled. Enable a server in Settings.", "A failure no line explains keeps its full message.")
    }

    func testOutcomeTextNeverShowsProcessOrBundleDetails() {
        let empty = ActionChecklist()
        XCTAssertEqual(empty.outcomeText(message: "Opened Notes (pid 91, com.apple.Notes). No window has appeared yet. Summarized it.", succeeded: true),
                       "Opened Notes. Summarized it.")
        XCTAssertEqual(empty.outcomeText(message: "", succeeded: true), "All done.")
    }

    func testFailureTitleBlamesAStepOnlyWhenOneFailed() {
        var step = ActionChecklist()
        step.addDone("Opened Helium")
        step.setOpenLine("Summarize the page")
        step.finish(.failed(message: "Timed out."))
        XCTAssertEqual(step.failureTitle, "One step didn’t work")

        var denied = ActionChecklist()
        denied.setOpenLine("Press save")
        denied.apply(.toolDenied(spec("press_shortcut")))
        XCTAssertEqual(denied.failureTitle, "Couldn’t finish", "A denial is the user's own call, not a step that broke.")
        XCTAssertEqual(ActionChecklist().failureTitle, "Couldn’t finish", "Nothing ran, for example when a plan was denied.")
    }

    func testFoldingKeepsTheNewestLines() {
        let lines = (1...8).map { ActionLine(status: .done, title: "Line \($0)") }
        let folded = lines.folded(limit: 6)
        XCTAssertEqual(folded.hidden, 2)
        XCTAssertEqual(folded.lines.map(\.title), (3...8).map { "Line \($0)" })
        XCTAssertEqual(lines.folded(limit: 20).hidden, 0)
    }
}
