import XCTest
@testable import Superkeet

final class CommandModeTogglePolicyTests: XCTestCase {
    func testIgnoresWhenActionsDisabled() {
        XCTAssertEqual(
            CommandModeTogglePolicy.action(
                actionsEnabled: false, isRecording: false, recordingRequested: false
            ),
            .ignore
        )
    }

    func testStartsWhenIdleAndEnabled() {
        XCTAssertEqual(
            CommandModeTogglePolicy.action(
                actionsEnabled: true, isRecording: false, recordingRequested: false
            ),
            .start
        )
    }

    func testStopsWhileRecording() {
        XCTAssertEqual(
            CommandModeTogglePolicy.action(
                actionsEnabled: true, isRecording: true, recordingRequested: false
            ),
            .stop
        )
    }

    func testStopsWhileStartIsPending() {
        XCTAssertEqual(
            CommandModeTogglePolicy.action(
                actionsEnabled: true, isRecording: false, recordingRequested: true
            ),
            .stop
        )
    }

    @MainActor
    func testStartsWhileAgentIsActive() {
        let router = AgentSessionControllerTests.FakeRouter(specs: [])
        let agent = AgentSessionController(router: router, plannerFactory: { nil })
        defer { agent.cancel() }
        agent.handleCommand("first task")
        XCTAssertTrue(agent.phase.isActive)
        XCTAssertEqual(
            CommandModeTogglePolicy.action(
                actionsEnabled: true, isRecording: false, recordingRequested: false
            ),
            .start
        )
    }
}
