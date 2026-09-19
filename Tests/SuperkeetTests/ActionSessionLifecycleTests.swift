import XCTest
import FoundationModels
@testable import Superkeet

@MainActor
final class ActionTestGate<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Error>?
    private(set) var entered = false
    private(set) var completed = false
    private(set) var wasCancelled = false

    func wait() async throws -> Value {
        entered = true
        defer { completed = true; wasCancelled = Task.isCancelled }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func resolve(_ result: Result<Value, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}

@MainActor
final class ActionSessionLifecycleTests: XCTestCase {
    final class Router: ActionRouting {
        var preparation: ActionTestGate<[ActionToolSpec]>?
        var firstExecution: ActionTestGate<String>?
        var specs = NativeOpenAction.tools
        var prepared = 0
        var executed = 0
        var cancelledApprovals = 0
        func prepareTools() async throws -> [ActionToolSpec] {
            prepared += 1
            if prepared == 1, let preparation { return try await preparation.wait() }
            return specs
        }
        func execute(spec: ActionToolSpec, argumentsJSON: String) async throws -> String {
            executed += 1
            if executed == 1, let firstExecution { return try await firstExecution.wait() }
            return "fresh-\(executed)"
        }
        func cancelPendingApprovals() { cancelledApprovals += 1 }
    }

    final class Planner: ActionPlanning {
        let completion = ActionTestGate<String>()
        var events: (@Sendable (ActionPlanEvent) -> Void)?
        var execute: (@Sendable (ActionToolSpec, String) async throws -> String)?
        func run(task: String, tools: [ActionToolSpec], maxSteps: Int,
                 execute: @escaping @Sendable (ActionToolSpec, String) async throws -> String,
                 onEvent: @escaping @Sendable (ActionPlanEvent) -> Void) async throws -> String {
            self.execute = execute
            events = onEvent
            return try await completion.wait()
        }
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for fixture state")
        throw ActionExecutionError.timedOut
    }

    func testCancelledPlannerCannotOverwriteNewRunOrClearItsTaskHandle() async throws {
        for result in [Result<String, Error>.success("stale result"), .failure(NativeOpenActionError.openFailed("stale failure"))] {
            let old = Planner()
            let new = Planner()
            let router = Router()
            var count = 0
            let controller = AgentSessionController(router: router, plannerFactory: {
                count += 1
                return count == 1 ? old : new
            })
            defer {
                controller.cancel()
                old.completion.resolve(.success("cleanup"))
                new.completion.resolve(.success("cleanup"))
            }
            controller.handleCommand("first task")
            try await waitFor { old.completion.entered }
            controller.cancel()
            controller.handleCommand("replacement task")
            try await waitFor { new.completion.entered }
            new.events?(.message("current message"))
            try await waitFor { controller.liveMessage == "current message" }
            let issue = AppSettings.shared.runtimeIssue
            let spec = NativeOpenAction.tools[0]
            old.events?(.planning)
            old.events?(.message("stale message"))
            old.events?(.toolStarted(spec))
            old.events?(.toolFinished(spec, "stale output"))
            old.events?(.toolFailed(spec, "stale failure"))
            old.events?(.toolDenied(spec))
            old.events?(.toolReused(spec))
            old.completion.resolve(result)
            try await waitFor { old.completion.completed }
            try await Task.sleep(for: .milliseconds(15))
            XCTAssertEqual(controller.phase, .planning)
            XCTAssertEqual(controller.commandText, "replacement task")
            XCTAssertEqual(controller.liveMessage, "current message")
            XCTAssertTrue(controller.activityLog.isEmpty)
            XCTAssertEqual(controller.stepIndex, 0)
            XCTAssertTrue(AppSettings.shared.isActionSessionActive)
            XCTAssertEqual(AppSettings.shared.actionStatusText, "Thinking…")
            XCTAssertEqual(AppSettings.shared.runtimeIssue, issue)
            XCTAssertEqual(router.cancelledApprovals, 1)
            let staleExecute = try XCTUnwrap(old.execute)
            do {
                _ = try await staleExecute(spec, "{}")
                XCTFail("A stale SDK callback must not dispatch")
            } catch { XCTAssertTrue(ActionErrorHandling.isCancellation(error)) }
            XCTAssertEqual(router.executed, 0)
            controller.cancel()
            new.completion.resolve(.success("late replacement result"))
            try await waitFor { new.completion.completed }
            XCTAssertTrue(new.completion.wasCancelled, "The old completion must not clear the replacement's task handle.")
            XCTAssertEqual(controller.phase, .cancelled)
        }
    }

    func testLateDiscoveryCannotStartOldPlanner() async throws {
        let old = Planner()
        let new = Planner()
        let router = Router()
        let gate = ActionTestGate<[ActionToolSpec]>()
        router.preparation = gate
        var count = 0
        let controller = AgentSessionController(router: router, plannerFactory: { count += 1; return count == 1 ? old : new })
        defer { controller.cancel(); gate.resolve(.success([])); new.completion.resolve(.success("cleanup")) }
        controller.handleCommand("first task")
        try await waitFor { gate.entered }
        controller.cancel()
        controller.handleCommand("replacement task")
        try await waitFor { new.completion.entered }
        gate.resolve(.success(NativeOpenAction.tools))
        try await waitFor { gate.completed }
        try await Task.sleep(for: .milliseconds(15))
        XCTAssertFalse(old.completion.entered)
        XCTAssertTrue(gate.wasCancelled)
        XCTAssertEqual(controller.commandText, "replacement task")
        XCTAssertEqual(controller.phase, .planning)
    }

    func testLateNativeResultCannotPolluteReplacementCacheOrProgress() async throws {
        let router = Router()
        let oldResult = ActionTestGate<String>()
        router.firstExecution = oldResult
        let planner = Planner()
        let controller = AgentSessionController(router: router, plannerFactory: { planner })
        defer { controller.cancel(); oldResult.resolve(.success("cleanup")); planner.completion.resolve(.success("cleanup")) }
        controller.handleCommand("open Discord")
        try await waitFor { oldResult.entered }
        controller.cancel()
        controller.handleCommand("replacement task")
        try await waitFor { planner.completion.entered }
        oldResult.resolve(.success("stale native output"))
        try await waitFor { oldResult.completed }
        try await Task.sleep(for: .milliseconds(15))
        XCTAssertTrue(oldResult.wasCancelled)
        XCTAssertTrue(controller.activityLog.isEmpty)
        XCTAssertEqual(controller.stepIndex, 0)
        let execute = try XCTUnwrap(planner.execute)
        let action = NativeOpenAction.openApp(name: "Discord")
        let fresh = try await execute(action.spec, action.argumentsJSON())
        let reused = try await execute(action.spec, action.argumentsJSON())
        XCTAssertEqual(fresh, "fresh-2")
        XCTAssertEqual(reused, "fresh-2")
        XCTAssertEqual(router.executed, 2)
        XCTAssertEqual(controller.stepIndex, 1)
        XCTAssertTrue(controller.activityLog.contains { $0.hasPrefix("Reused") })
    }

    func testClosedRunCannotBeReactivatedByQueuedEventsOrIdleCancel() async throws {
        let planner = Planner()
        let controller = AgentSessionController(router: Router(), plannerFactory: { planner })
        defer { controller.cancel(); planner.completion.resolve(.success("cleanup")) }
        controller.handleCommand("a task")
        try await waitFor { planner.completion.entered }
        planner.completion.resolve(.success("final result"))
        try await waitFor { controller.phase == .finished("final result") }
        planner.events?(.planning)
        planner.events?(.message("stale partial result"))
        try await Task.sleep(for: .milliseconds(15))
        controller.cancel()
        XCTAssertEqual(controller.phase, .finished("final result"))
        XCTAssertEqual(controller.liveMessage, "final result")
        XCTAssertFalse(AppSettings.shared.isActionSessionActive)
        controller.reset()
        planner.events?(.planning)
        try await Task.sleep(for: .milliseconds(15))
        XCTAssertEqual(controller.phase, .idle)
    }

    func testCancellationBeforeStartupCannotReviveResetSession() async throws {
        let router = Router()
        let planner = Planner()
        var factories = 0
        let controller = AgentSessionController(router: router, plannerFactory: { factories += 1; return planner })
        defer { controller.cancel(); planner.completion.resolve(.success("cleanup")) }
        controller.handleCommand("cancel before startup")
        controller.handleCommand("queued before startup")
        XCTAssertEqual(controller.queuedCommands, ["queued before startup"])
        controller.cancel()
        XCTAssertTrue(controller.queuedCommands.isEmpty)
        controller.reset()
        try await Task.sleep(for: .milliseconds(15))
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(factories, 0)
        XCTAssertEqual(router.prepared, 0)
        controller.handleCommand("replacement task")
        try await waitFor { planner.completion.entered }
        XCTAssertEqual(factories, 1)
        XCTAssertEqual(controller.commandText, "replacement task")
    }

    func testStartingAgainClearsOnlyThePreviousRunOwnedRuntimeIssue() async throws {
        let initialIssue = AppSettings.shared.runtimeIssue
        defer { AppSettings.shared.runtimeIssue = initialIssue }
        for unrelatedIssue in [false, true] {
            let old = Planner()
            let new = Planner()
            var factories = 0
            let controller = AgentSessionController(router: Router(), plannerFactory: { factories += 1; return factories == 1 ? old : new })
            defer { controller.cancel(); old.completion.resolve(.success("cleanup")); new.completion.resolve(.success("cleanup")) }
            controller.handleCommand("first task")
            try await waitFor { old.completion.entered }
            old.completion.resolve(.failure(NativeOpenActionError.openFailed("fixture failure")))
            try await waitFor { !controller.phase.isActive }
            XCTAssertTrue(AppSettings.shared.runtimeIssue?.contains("fixture failure") == true)
            if unrelatedIssue { AppSettings.shared.runtimeIssue = "Speech engine issue" }
            controller.handleCommand("replacement task")
            try await waitFor { new.completion.entered }
            XCTAssertEqual(AppSettings.shared.runtimeIssue, unrelatedIssue ? "Speech engine issue" : nil)
        }
    }

    @available(macOS 26.0, *)
    func testWrappedToolCancellationEndsAsCancelledWithoutRuntimeFailure() async throws {
        let planner = Planner()
        let controller = AgentSessionController(router: Router(), plannerFactory: { planner })
        defer { controller.cancel(); planner.completion.resolve(.success("cleanup")) }
        let priorIssue = AppSettings.shared.runtimeIssue
        controller.handleCommand("a task")
        try await waitFor { planner.completion.entered }
        let tool = try XCTUnwrap(MCPToolBridge(spec: NativeOpenAction.tools[0], execute: { _, _ in "unused" }))
        planner.completion.resolve(.failure(LanguageModelSession.ToolCallError(tool: tool, underlyingError: CancellationError())))
        try await waitFor { !controller.phase.isActive }
        XCTAssertEqual(controller.phase, .cancelled)
        XCTAssertEqual(AppSettings.shared.runtimeIssue, priorIssue)
        XCTAssertFalse(controller.activityLog.contains { $0.hasPrefix("Failed") })
    }

    final class ApprovalRouter: ActionRouting {
        let delegate: ActionToolRouter
        init(_ delegate: ActionToolRouter) { self.delegate = delegate }
        func prepareTools() async throws -> [ActionToolSpec] { NativeOpenAction.tools }
        func execute(spec: ActionToolSpec, argumentsJSON: String) async throws -> String {
            try await delegate.execute(spec: spec, argumentsJSON: argumentsJSON)
        }
        func cancelPendingApprovals() { delegate.cancelPendingApprovals() }
    }

    final class NativeExecutor: NativeActionExecuting {
        var actions: [NativeOpenAction] = []
        func execute(_ action: NativeOpenAction) async throws -> String {
            actions.append(action)
            return "fixture completed"
        }
    }

    func testCancellingSDKToolTaskDrainsOnlyOldApprovalsAndNeverDispatchesIt() async throws {
        let settings = AppSettings.shared
        let policy = settings.actionApprovalPolicy
        let enabled = settings.actionAuditEnabled
        settings.actionApprovalPolicy = .alwaysAsk
        settings.actionAuditEnabled = true
        defer { settings.actionApprovalPolicy = policy; settings.actionAuditEnabled = enabled }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        defer { try? FileManager.default.removeItem(at: file) }
        let audit = ActionAuditStore(fileURL: file)
        let approvals = ActionApprovalController()
        let native = NativeExecutor()
        let router = ApprovalRouter(ActionToolRouter(approvals: approvals, audit: audit, settings: settings, nativeExecutor: native))
        let old = Planner()
        let new = Planner()
        var count = 0
        let controller = AgentSessionController(router: router, plannerFactory: { count += 1; return count == 1 ? old : new })
        defer { controller.cancel(); old.completion.resolve(.success("cleanup")); new.completion.resolve(.success("cleanup")) }
        controller.handleCommand("first task")
        try await waitFor { old.completion.entered }
        let oldExecute = try XCTUnwrap(old.execute)
        let oldTool = Task { try await oldExecute(NativeOpenAction.tools[0], #"{"name":"Old App"}"#) }
        try await waitFor { approvals.pending != nil }
        controller.cancel()
        XCTAssertNil(approvals.pending)
        controller.handleCommand("new task")
        try await waitFor { new.completion.entered }
        let newExecute = try XCTUnwrap(new.execute)
        let newTool = Task { try await newExecute(NativeOpenAction.tools[0], #"{"name":"New App"}"#) }
        try await waitFor { approvals.pending != nil }
        let newID = try XCTUnwrap(approvals.pending?.id)
        old.completion.resolve(.failure(NativeOpenActionError.openFailed("late old failure")))
        do { _ = try await oldTool.value; XCTFail("Old approval must cancel") } catch { XCTAssertTrue(ActionErrorHandling.isCancellation(error)) }
        XCTAssertFalse(oldTool.isCancelled, "The controller must cancel its owned work even when the SDK callback task is independent.")
        XCTAssertEqual(approvals.pending?.id, newID)
        XCTAssertTrue(native.actions.isEmpty)
        approvals.resolve(.approve, requestID: newID)
        _ = try await newTool.value
        XCTAssertEqual(native.actions, [.openApp(name: "New App")])
        XCTAssertEqual(audit.entries().map(\.outcome), ["cancelled", "succeeded"])
    }
}
