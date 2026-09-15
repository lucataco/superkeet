import XCTest
@testable import Superkeet

@MainActor
final class AgentSessionControllerTests: XCTestCase {

    final class FakeRouter: ActionRouting {
        var specs: [ActionToolSpec]
        var failure: Error?
        private(set) var executed: [String] = []

        init(specs: [ActionToolSpec], failure: Error? = nil) {
            self.specs = specs
            self.failure = failure
        }

        func prepareTools() async throws -> [ActionToolSpec] { specs }

        func execute(spec: ActionToolSpec, argumentsJSON: String) async throws -> String {
            executed.append(spec.toolName)
            if let failure { throw failure }
            return "tool-output"
        }
    }

    final class FakePlanner: ActionPlanning {
        let calls: Int
        let result: String
        let arguments: (Int) -> String
        private(set) var invoked = false

        init(
            calls: Int = 1,
            result: String = "done",
            arguments: @escaping (Int) -> String = { "{\"n\":\($0)}" }
        ) {
            self.calls = calls
            self.result = result
            self.arguments = arguments
        }

        func run(
            task: String,
            tools: [ActionToolSpec],
            maxSteps: Int,
            execute: @escaping @Sendable (ActionToolSpec, String) async throws -> String,
            onEvent: @escaping @Sendable (ActionPlanEvent) -> Void
        ) async throws -> String {
            invoked = true
            for index in 0..<calls {
                _ = try await execute(tools[0], arguments(index))
            }
            onEvent(.message(result))
            return result
        }
    }

    private func makeSpec(name: String = "echo", risk: ActionToolRisk = .readOnly) -> ActionToolSpec {
        ActionToolSpec(descriptor: MCPToolDescriptor(
            serverID: UUID(),
            serverName: "test",
            name: name,
            title: nil,
            description: "Echo tool",
            risk: risk,
            inputSchemaJSON: "{}"
        ))
    }

    private func waitUntilFinished(_ controller: AgentSessionController, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while controller.phase.isActive && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testPhaseIsActiveOnlyWhilePlanningOrRunning() {
        XCTAssertTrue(AgentSessionController.Phase.planning.isActive)
        XCTAssertTrue(AgentSessionController.Phase.running.isActive)
        XCTAssertFalse(AgentSessionController.Phase.idle.isActive)
        XCTAssertFalse(AgentSessionController.Phase.finished("done").isActive)
        XCTAssertFalse(AgentSessionController.Phase.failed("nope").isActive)
        XCTAssertFalse(AgentSessionController.Phase.cancelled.isActive)
    }

    func testPhaseIsOutcomeOnlyWhenFinishedOrFailed() {
        XCTAssertTrue(AgentSessionController.Phase.finished("done").isOutcome)
        XCTAssertTrue(AgentSessionController.Phase.failed("nope").isOutcome)
        XCTAssertFalse(AgentSessionController.Phase.idle.isOutcome)
        XCTAssertFalse(AgentSessionController.Phase.planning.isOutcome)
        XCTAssertFalse(AgentSessionController.Phase.running.isOutcome)
        XCTAssertFalse(AgentSessionController.Phase.cancelled.isOutcome)
    }

    func testPhaseShowsHUDWhileWorkingAndOnOutcome() {
        XCTAssertTrue(AgentSessionController.Phase.planning.showsHUD)
        XCTAssertTrue(AgentSessionController.Phase.running.showsHUD)
        XCTAssertTrue(AgentSessionController.Phase.finished("done").showsHUD)
        XCTAssertTrue(AgentSessionController.Phase.failed("nope").showsHUD)
        XCTAssertFalse(AgentSessionController.Phase.idle.showsHUD)
        XCTAssertFalse(AgentSessionController.Phase.cancelled.showsHUD)
    }

    func testRunsCommandToCompletion() async {
        let router = FakeRouter(specs: [makeSpec()])
        let planner = FakePlanner(calls: 1)
        let controller = AgentSessionController(
            settings: .shared,
            router: router,
            plannerFactory: { planner }
        )

        controller.handleCommand("do the thing")
        await waitUntilFinished(controller)

        XCTAssertEqual(controller.phase, .finished("done"))
        XCTAssertEqual(router.executed, ["echo"])
        XCTAssertTrue(planner.invoked)
    }

    func testFailsWhenPlannerUnavailable() async {
        let router = FakeRouter(specs: [makeSpec()])
        let controller = AgentSessionController(
            settings: .shared,
            router: router,
            plannerFactory: { nil }
        )

        controller.handleCommand("do the thing")
        await waitUntilFinished(controller)

        XCTAssertEqual(controller.phase, .failed(ActionExecutionError.unavailable.localizedDescription))
    }

    func testFailsWhenNoToolsAvailable() async {
        let router = FakeRouter(specs: [])
        let planner = FakePlanner()
        let controller = AgentSessionController(
            settings: .shared,
            router: router,
            plannerFactory: { planner }
        )

        controller.handleCommand("do the thing")
        await waitUntilFinished(controller)

        XCTAssertEqual(controller.phase, .failed(ActionExecutionError.noTools.localizedDescription))
        XCTAssertFalse(planner.invoked)
    }

    func testEnforcesStepBudget() async {
        let settings = AppSettings.shared
        let original = settings.actionMaxSteps
        settings.actionMaxSteps = 2
        defer { settings.actionMaxSteps = original }

        let router = FakeRouter(specs: [makeSpec()])
        let planner = FakePlanner(calls: 3)
        let controller = AgentSessionController(
            settings: settings,
            router: router,
            plannerFactory: { planner }
        )

        controller.handleCommand("loop")
        await waitUntilFinished(controller)

        XCTAssertEqual(router.executed.count, 2)
        XCTAssertEqual(controller.stepTotal, 2)
        XCTAssertEqual(controller.stepIndex, 2)
        if case .failed(let message) = controller.phase {
            XCTAssertEqual(message, ActionExecutionError.stepBudgetExceeded.localizedDescription)
        } else {
            XCTFail("Expected step budget failure, got \(controller.phase)")
        }
    }

    func testReusesIdenticalToolCalls() async {
        let router = FakeRouter(specs: [makeSpec()])
        let planner = FakePlanner(calls: 2, arguments: { _ in "{}" })
        let controller = AgentSessionController(
            settings: .shared,
            router: router,
            plannerFactory: { planner }
        )

        controller.handleCommand("echo twice")
        await waitUntilFinished(controller)

        XCTAssertEqual(router.executed.count, 1, "Identical tool calls should be reused, not re-run.")
        XCTAssertEqual(controller.phase, .finished("done"))
        XCTAssertTrue(controller.activityLog.contains { $0.hasPrefix("Reused") })
    }

    func testApprovalDenialStopsExecution() async {
        let router = FakeRouter(specs: [makeSpec()], failure: ActionExecutionError.approvalDenied("echo"))
        let planner = FakePlanner(calls: 1)
        let controller = AgentSessionController(
            settings: .shared,
            router: router,
            plannerFactory: { planner }
        )

        controller.handleCommand("do the thing")
        await waitUntilFinished(controller)

        if case .failed(let message) = controller.phase {
            XCTAssertTrue(message.contains("not approved"))
        } else {
            XCTFail("Expected approval denial, got \(controller.phase)")
        }
    }
}
