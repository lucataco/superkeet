import AVFoundation
import XCTest
@testable import Superkeet

final class MicrophoneAccessTests: XCTestCase {
    func testDecisionForEachStatus() {
        XCTAssertEqual(MicrophoneAccess.decision(for: .authorized), .allowed)
        XCTAssertEqual(MicrophoneAccess.decision(for: .notDetermined), .needsPrompt)
        XCTAssertEqual(MicrophoneAccess.decision(for: .denied), .denied)
        XCTAssertEqual(MicrophoneAccess.decision(for: .restricted), .denied)
    }

    func testAuthorizedProceedsWithoutPrompting() async {
        var prompted = false
        let allowed = await MicrophoneAccess.ensureAccess(status: { .authorized }, requestAccess: {
            prompted = true
            return false
        })
        XCTAssertTrue(allowed)
        XCTAssertFalse(prompted)
    }

    func testDeniedNeverPromptsAndBlocks() async {
        var prompted = false
        let allowed = await MicrophoneAccess.ensureAccess(status: { .denied }, requestAccess: {
            prompted = true
            return true
        })
        XCTAssertFalse(allowed)
        XCTAssertFalse(prompted)
    }

    func testUndeterminedUsesPromptResult() async {
        let granted = await MicrophoneAccess.ensureAccess(status: { .notDetermined }, requestAccess: { true })
        let refused = await MicrophoneAccess.ensureAccess(status: { .notDetermined }, requestAccess: { false })
        XCTAssertTrue(granted)
        XCTAssertFalse(refused)
    }
}
