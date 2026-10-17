import AppKit
import XCTest
@testable import Superkeet

final class RecordingStartFeedbackTests: XCTestCase {
    private let all: [RecordingStartFeedback] = [.waitingForEngine, .microphoneDenied, .engineFailed, .notStarted, .releasedEarly]

    func testOverlayNoticesFitTheNarrowestOverlay() {
        // The status pill adds a 14 pt icon, 8 pt spacing and 14 pt padding on each side. Beside
        // a notch, the shelf leaves about 180 pt for it; the island is 200 pt wide.
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let room = min(RecordingOverlayWindowController.gradientIslandSize.width, 180)
        for feedback in all {
            let width = (feedback.notice as NSString).size(withAttributes: [.font: font]).width + 14 + 8 + 28
            XCTAssertLessThanOrEqual(width, room, "\(feedback.notice) would be cut off")
        }
    }

    func testEveryProblemSaysSomethingDifferent() {
        XCTAssertEqual(Set(all.map(\.notice)).count, all.count)
        XCTAssertEqual(Set(all.map(\.status)).count, all.count)
        XCTAssertTrue(RecordingStartFeedback.releasedEarly.status.contains("start sound"), "Says how to avoid it next time.")
    }
}
