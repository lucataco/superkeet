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
}
