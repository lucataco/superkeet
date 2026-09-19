import XCTest
@testable import Superkeet

@MainActor
final class ActionHUDPlacementTests: XCTestCase {
    func testHUDDropsBelowTopAnchoredRecordingOverlaysOnlyWhileRecording() {
        for style in OverlayAnimationStyle.allCases {
            let recording = ActionHUDWindowController.recordingOverlayClearance(isRecording: true, style: style)
            let idle = ActionHUDWindowController.recordingOverlayClearance(isRecording: false, style: style)
            XCTAssertEqual(idle, 0, "\(style)")
            if style.anchorsToTop {
                XCTAssertGreaterThan(recording, 0, "\(style) draws along the top edge, so the HUD must move down.")
            } else {
                XCTAssertEqual(recording, 0, "\(style) leaves the top edge free.")
            }
        }
    }

    func testTopAnchoredStyles() {
        XCTAssertEqual(OverlayAnimationStyle.allCases.filter(\.anchorsToTop), [.gradientIsland, .notchShelf])
    }

    func testVisibilityShowsForQuestionsWorkOutcomesAndEarlyLaunches() {
        typealias Visibility = ActionHUDWindowController.Visibility
        XCTAssertFalse(Visibility().isShown)
        XCTAssertTrue(Visibility(hasPendingApproval: true).isShown)
        XCTAssertTrue(Visibility(hasPendingPlan: true).isShown)
        XCTAssertTrue(Visibility(phase: .running).isShown)
        XCTAssertTrue(Visibility(phase: .finished("done")).isShown)
        XCTAssertTrue(Visibility(phase: .failed("no")).isShown)
        XCTAssertFalse(Visibility(phase: .cancelled).isShown)
        XCTAssertTrue(Visibility(hasSpeculativeActivity: true).isShown)
    }

    func testKeyboardIsTakenOnlyWhileAQuestionIsPending() {
        typealias Visibility = ActionHUDWindowController.Visibility
        XCTAssertTrue(Visibility(hasPendingApproval: true, phase: .running).wantsKeyboard)
        XCTAssertTrue(Visibility(hasPendingPlan: true, phase: .planning).wantsKeyboard)
        XCTAssertFalse(Visibility(phase: .running).wantsKeyboard, "Typing in the user's app must not be captured while a command merely runs.")
        XCTAssertFalse(Visibility(phase: .finished("done")).wantsKeyboard)
        XCTAssertFalse(Visibility(hasSpeculativeActivity: true).wantsKeyboard)
    }

    func testAutoHideOnlyAfterAFinishedCommandWithNothingPending() {
        typealias Visibility = ActionHUDWindowController.Visibility
        XCTAssertTrue(Visibility(phase: .finished("done")).autoHides)
        XCTAssertFalse(Visibility(phase: .failed("no")).autoHides, "Failures stay until dismissed.")
        XCTAssertFalse(Visibility(phase: .running).autoHides)
        XCTAssertFalse(Visibility(hasPendingApproval: true, phase: .finished("done")).autoHides)
    }

    func testListeningShowsTheHUDWithoutTakingKeyboardOrAutoHiding() {
        typealias Visibility = ActionHUDWindowController.Visibility
        for phase in [AgentSessionController.Phase.idle, .cancelled, .planning, .running] {
            let visibility = Visibility(phase: phase, isListening: true)
            XCTAssertTrue(visibility.isShown, "\(phase)")
            XCTAssertFalse(visibility.wantsKeyboard, "\(phase)")
            XCTAssertFalse(visibility.autoHides, "\(phase)")
            XCTAssertNil(visibility.autoHideAction, "\(phase)")
        }
    }

    func testQuestionsStillTakeKeyboardWhileAnotherCommandIsListening() {
        typealias Visibility = ActionHUDWindowController.Visibility
        for visibility in [
            Visibility(hasPendingApproval: true, phase: .running, isListening: true),
            Visibility(hasPendingPlan: true, phase: .planning, isListening: true),
            Visibility(hasPendingApproval: true, phase: .finished("done"), isListening: true)
        ] {
            XCTAssertTrue(visibility.isShown)
            XCTAssertTrue(visibility.wantsKeyboard)
            XCTAssertNil(visibility.autoHideAction, "A pending question must not be dismissed by an outcome timer.")
        }
    }

    func testFinishedOutcomeDismissalRevealsListeningInsteadOfHidingTheHUD() {
        var visibility = ActionHUDWindowController.Visibility(phase: .finished("done"), isListening: true)
        XCTAssertEqual(visibility.autoHideAction, .dismissOutcome)
        XCTAssertFalse(visibility.autoHides)
        XCTAssertEqual(visibility.autoHideDelay, 2)
        visibility.phase = .idle
        XCTAssertTrue(visibility.isShown, "Dismissing Done must leave the transcript on screen.")
        XCTAssertFalse(visibility.wantsKeyboard)
        XCTAssertNil(visibility.autoHideAction)
    }

    func testOutcomeDelayIsShorterWhenListeningOrCommandsAreQueued() {
        typealias Visibility = ActionHUDWindowController.Visibility
        let outcome = AgentSessionController.Phase.finished("done")
        XCTAssertEqual(Visibility(phase: outcome).autoHideDelay, 8)
        XCTAssertEqual(Visibility(phase: outcome).autoHideAction, .hide)
        XCTAssertEqual(Visibility(phase: outcome, isListening: true).autoHideDelay, 2)
        XCTAssertEqual(Visibility(phase: outcome, hasQueuedCommands: true).autoHideDelay, 2)
        XCTAssertEqual(Visibility(phase: outcome, isListening: true, hasQueuedCommands: true).autoHideDelay, 2)
    }

    func testFailuresStayVisibleWhileListeningUntilDismissed() {
        let visibility = ActionHUDWindowController.Visibility(phase: .failed("no"), isListening: true)
        XCTAssertTrue(visibility.isShown)
        XCTAssertFalse(visibility.wantsKeyboard)
        XCTAssertFalse(visibility.autoHides)
        XCTAssertNil(visibility.autoHideAction)
    }
}
