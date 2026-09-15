import XCTest
@testable import Superkeet

final class CommandModeTogglePolicyTests: XCTestCase {
    func testIgnoresWhenActionsDisabled() {
        XCTAssertEqual(
            CommandModeTogglePolicy.action(
                actionsEnabled: false, isRecording: false, recordingRequested: false, agentActive: false
            ),
            .ignore
        )
    }

    func testStartsWhenIdleAndEnabled() {
        XCTAssertEqual(
            CommandModeTogglePolicy.action(
                actionsEnabled: true, isRecording: false, recordingRequested: false, agentActive: false
            ),
            .start
        )
    }

    func testStopsWhileRecording() {
        XCTAssertEqual(
            CommandModeTogglePolicy.action(
                actionsEnabled: true, isRecording: true, recordingRequested: false, agentActive: false
            ),
            .stop
        )
    }

    func testStopsWhileStartIsPending() {
        XCTAssertEqual(
            CommandModeTogglePolicy.action(
                actionsEnabled: true, isRecording: false, recordingRequested: true, agentActive: false
            ),
            .stop
        )
    }

    func testIgnoresWhileAgentIsActive() {
        XCTAssertEqual(
            CommandModeTogglePolicy.action(
                actionsEnabled: true, isRecording: false, recordingRequested: false, agentActive: true
            ),
            .ignore
        )
    }
}
