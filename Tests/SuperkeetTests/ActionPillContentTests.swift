import AppKit
import XCTest
@testable import Superkeet

final class ActionPillContentTests: XCTestCase {
    private typealias Content = ActionPillContent

    private func pill(_ state: ActionPillState, file: StaticString = #filePath, line: UInt = #line) -> Content? {
        guard case .pill(let content) = Content.presentation(for: state) else {
            XCTFail("Expected the pill, got the card", file: file, line: line)
            return nil
        }
        return content
    }

    // MARK: - States

    func testIdleSessionShowsThePlaceholder() {
        let content = pill(ActionPillState(isSessionActive: true))
        XCTAssertEqual(content, Content(glyph: .bars(active: false), text: Content.sessionPlaceholder, tone: .placeholder))
    }

    func testOpenTakeWithNoWordsYetShowsThePlaceholder() {
        XCTAssertEqual(pill(ActionPillState(isSessionActive: true, transcript: ""))?.text, Content.sessionPlaceholder)
        XCTAssertEqual(pill(ActionPillState(transcript: "  "))?.text, Content.takePlaceholder,
                       "A single take outside a session asks for a command.")
    }

    func testSpeakingShowsATickerOfTheWords() {
        let content = pill(ActionPillState(isSessionActive: true, transcript: "Can you open up\n Notes  for me"))
        XCTAssertEqual(content, Content(glyph: .bars(active: true), text: "Can you open up Notes for me", isTicker: true))
    }

    func testAConfirmationSitsBesideTheTickerWhileSpeaking() {
        let content = pill(ActionPillState(isSessionActive: true, transcript: "and then type hello", confirmation: "Opened TextEdit"))
        XCTAssertEqual(content?.isTicker, true)
        XCTAssertEqual(content?.checkBeside, "Opened TextEdit")
    }

    func testAFinishedActionShowsAConfirmation() {
        let content = pill(ActionPillState(phase: .running, isSessionActive: true, runningStep: "Type “hello”", confirmation: "Opened TextEdit"))
        XCTAssertEqual(content, Content(glyph: .check, text: "Opened TextEdit"))
    }

    func testWorkingShowsTheSpinnerAndTheStep() {
        XCTAssertEqual(pill(ActionPillState(phase: .running, isSessionActive: true, runningStep: "Summarize the page")),
                       Content(glyph: .spinner, text: "Summarize the page"))
        XCTAssertEqual(pill(ActionPillState(phase: .planning, liveMessage: "Reading the page…"))?.text, "Reading the page…")
        XCTAssertEqual(pill(ActionPillState(phase: .planning, liveMessage: " "))?.text, Content.workingFallback)
    }

    func testFinishedWithoutAPendingConfirmationSaysDone() {
        XCTAssertEqual(pill(ActionPillState(phase: .finished("ok"), isSessionActive: true)), Content(glyph: .check, text: "Done"))
    }

    func testAnAnswerInWordsIsShownInsteadOfDoneAndWithoutACheck() {
        let state = ActionPillState(phase: .finished("ok"), isSessionActive: true, reply: "I can’t click buttons.")
        XCTAssertEqual(pill(state), Content(glyph: .bars(active: false), text: "I can’t click buttons."))

        var checklist = ActionChecklist()
        XCTAssertNil(Content.replyLine(in: checklist))
        checklist.addReply(BuiltInActionsReply.text(for: "I can’t click buttons."))
        XCTAssertEqual(Content.replyLine(in: checklist), "I can’t click buttons.", "One line holds the first sentence; the card has the rest.")
    }

    func testFailureDuringASessionIsOneOrangeLine() {
        let content = pill(ActionPillState(phase: .failed("no"), isSessionActive: true, failure: "Open Helium: Not installed."))
        XCTAssertEqual(content, Content(glyph: .warning, text: "Open Helium: Not installed.", tone: .warning))
    }

    func testNewSpeechReplacesTheFailureLine() {
        let content = pill(ActionPillState(phase: .failed("no"), isSessionActive: true, transcript: "open notes", failure: "Open Helium failed"))
        XCTAssertEqual(content?.isTicker, true)
        XCTAssertEqual(content?.text, "open notes")
    }

    func testFailureOutsideAListeningSessionKeepsTheCard() {
        XCTAssertEqual(Content.presentation(for: ActionPillState(phase: .failed("no"), failure: "x")), .card)
    }

    func testQuestionsExpansionAndTheSettingShowTheCard() {
        XCTAssertEqual(Content.presentation(for: ActionPillState(hasQuestion: true, phase: .running, isSessionActive: true)), .card)
        XCTAssertEqual(Content.presentation(for: ActionPillState(userExpanded: true, isSessionActive: true)), .card)
        XCTAssertEqual(Content.presentation(for: ActionPillState(compactEnabled: false, isSessionActive: true)), .card)
        XCTAssertTrue(Content.presentation(for: ActionPillState(isSessionActive: true)).isPill)
        XCTAssertFalse(Content.Presentation.card.isPill)
    }

    // MARK: - Ticker

    func testTickerTailKeepsShortTextWhole() {
        XCTAssertEqual(Content.tickerTail("Open Notes"), "Open Notes")
        XCTAssertEqual(Content.tickerTail("  Open \n Notes "), "Open Notes")
    }

    func testTickerTailKeepsTheEndAndStartsOnAWord() {
        let text = "Can you open up the Notes app for me and inside this new note let's make the title say hello world"
        let tail = Content.tickerTail(text, limit: 40)
        XCTAssertTrue(text.hasSuffix(tail))
        XCTAssertLessThanOrEqual(tail.count, 40)
        XCTAssertEqual(tail, "let’s make the title say hello world".replacingOccurrences(of: "’", with: "'"))
        XCTAssertFalse(tail.hasPrefix(" "))
    }

    func testTickerTailCutsMidWordWhenNoSpaceIsNear() {
        let text = String(repeating: "a", count: 60) + " end"
        XCTAssertEqual(Content.tickerTail(text, limit: 20), String(repeating: "a", count: 16) + " end")
    }

    // MARK: - Confirmations, steps, failures

    func testNewlyDonePicksTheNewestUnseenFinishedLine() {
        let lines = [
            ActionLine(status: .done, title: "Opened TextEdit"),
            ActionLine(status: .done, title: "New document"),
            ActionLine(status: .running, title: "Type “hello”")
        ]
        XCTAssertEqual(Content.newlyDone(in: lines, seen: []), "New document")
        XCTAssertNil(Content.newlyDone(in: lines, seen: ["Opened TextEdit", "New document"]))
        XCTAssertEqual(Content.newlyDone(in: lines, seen: ["New document"]), "Opened TextEdit")
        XCTAssertEqual(Content.doneTitles(in: lines), ["Opened TextEdit", "New document"])
        XCTAssertEqual(Content.runningStep(in: lines), "Type “hello”")
        XCTAssertNil(Content.runningStep(in: Array(lines.prefix(2))))
    }

    func testFailureLineNamesTheFailedStepAndReason() {
        var checklist = ActionChecklist()
        checklist.addDone("Opened Helium")
        checklist.setOpenLine("Summarize the page")
        checklist.finish(.failed(message: "Couldn't read the page. No browser tools are enabled."))
        XCTAssertEqual(Content.failureLine(checklist: checklist, message: "ignored"),
                       "Summarize the page: Couldn't read the page.")
    }

    func testLongFailureLinesKeepJustTheReason() {
        var checklist = ActionChecklist()
        checklist.setOpenLine("Search for “parakeet transcription benchmarks”")
        checklist.finish(.failed(message: "The browser didn't respond."))
        XCTAssertEqual(Content.failureLine(checklist: checklist, message: "ignored"), "The browser didn't respond.")
    }

    func testFailureLineFallsBackToTheMessage() {
        XCTAssertEqual(Content.failureLine(checklist: ActionChecklist(), message: "Nothing to do here. (code 4)"),
                       "Nothing to do here.")
        XCTAssertEqual(Content.failureLine(checklist: ActionChecklist(), message: ""), ActionChecklist().failureTitle)
    }

    func testFailureLineForADeniedStep() {
        var checklist = ActionChecklist()
        checklist.setOpenLine("Delete the file")
        checklist.apply(.toolDenied(ActionToolSpec(descriptor: MCPToolDescriptor(
            serverID: UUID(), serverName: "fs", name: "delete", title: nil, description: nil, risk: .destructive, inputSchemaJSON: "{}"
        ))))
        XCTAssertEqual(Content.failureLine(checklist: checklist, message: "denied"), "Delete the file: not approved")
    }

    // MARK: - Placement

    func testPillHangsUnderTheNotch() {
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = NSRect(x: 0, y: 0, width: 1512, height: 944)
        let metrics = OverlayGeometry.notchMetrics(
            screenFrame: screen, visibleFrame: visible, topSafeInset: 38,
            auxiliaryTopLeft: NSRect(x: 0, y: 944, width: 662, height: 38),
            auxiliaryTopRight: NSRect(x: 850, y: 944, width: 662, height: 38)
        )
        let size = NSSize(width: 430, height: 36)
        let origin = OverlayGeometry.notchPillOrigin(size: size, screenFrame: screen, visibleFrame: visible, metrics: metrics, clearance: 72)
        XCTAssertEqual(origin.x, 756 - 215, "Centered on the notch.")
        XCTAssertEqual(origin.y + size.height, 982 - 38 - OverlayGeometry.notchPillGap,
                       "Top edge just under the notch; recording overlays live in the menu band, so no clearance.")
    }

    func testPillSitsUnderTheMenuBarWithoutANotch() {
        let screen = NSRect(x: 1512, y: 0, width: 1920, height: 1080)
        let visible = NSRect(x: 1512, y: 0, width: 1920, height: 1055)
        let metrics = OverlayGeometry.notchMetrics(
            screenFrame: screen, visibleFrame: visible, topSafeInset: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil
        )
        let size = NSSize(width: 430, height: 36)
        let origin = OverlayGeometry.notchPillOrigin(size: size, screenFrame: screen, visibleFrame: visible, metrics: metrics)
        XCTAssertEqual(origin.x, 1512 + 960 - 215)
        XCTAssertEqual(origin.y + size.height, 1055 - OverlayGeometry.menuBarPillGap)
        let below = OverlayGeometry.notchPillOrigin(size: size, screenFrame: screen, visibleFrame: visible, metrics: metrics, clearance: 72)
        XCTAssertEqual(origin.y - below.y, 72, "A recording overlay under the menu bar pushes the pill down.")
    }

    // MARK: - Visibility with the pill

    @MainActor
    func testCompactFailuresClearThemselvesWhileListening() {
        typealias Visibility = ActionHUDWindowController.Visibility
        let failed = Visibility(phase: .failed("no"), isListening: true, compact: true)
        XCTAssertEqual(failed.autoHideAction, .dismissOutcome)
        XCTAssertEqual(failed.autoHideDelay, ActionPillContent.failureDuration)
        XCTAssertNil(Visibility(phase: .failed("no"), compact: true).autoHideAction,
                     "Outside a session the failure card stays until dismissed.")
        XCTAssertNil(Visibility(hasPendingApproval: true, phase: .failed("no"), isListening: true, compact: true).autoHideAction)
    }

    @MainActor
    func testAnAnswerStaysLongEnoughToRead() {
        typealias Visibility = ActionHUDWindowController.Visibility
        let answered = Visibility(phase: .finished("ok"), isListening: true, compact: true, hasReply: true)
        XCTAssertEqual(answered.autoHideDelay, ActionPillContent.replyDuration)
        XCTAssertEqual(Visibility(phase: .failed("no"), isListening: true, compact: true, hasReply: true).autoHideDelay,
                       ActionPillContent.failureDuration)
    }

    @MainActor
    func testCompactConfirmationsAreBrief() {
        typealias Visibility = ActionHUDWindowController.Visibility
        XCTAssertEqual(Visibility(phase: .finished("ok"), isListening: true, compact: true).autoHideDelay,
                       ActionPillContent.confirmationDuration)
        XCTAssertEqual(Visibility(phase: .finished("ok"), compact: true).autoHideAction, .hide)
        XCTAssertLessThan(Visibility(phase: .finished("ok"), compact: true).autoHideDelay,
                          Visibility(phase: .finished("ok")).autoHideDelay)
    }

    @MainActor
    func testPillSpeechBarsSwayWithinBounds() {
        for time in stride(from: 0.0, to: 2.0, by: 0.05) {
            let heights = PillVoiceBars.swayHeights(at: time)
            XCTAssertEqual(heights.count, 5)
            XCTAssertTrue(heights.allSatisfy { $0 >= 0.3 && $0 <= 1.0 })
        }
    }
}
