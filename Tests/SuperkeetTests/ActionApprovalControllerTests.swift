import XCTest
@testable import Superkeet

@MainActor
final class ActionApprovalControllerTests: XCTestCase {
    private func request(_ name: String) -> ActionApprovalRequest {
        let spec = ActionToolSpec(descriptor: MCPToolDescriptor(serverID: UUID(), serverName: "fixture", name: name,
            title: nil, description: nil, risk: .mutating, inputSchemaJSON: "{}"))
        return ActionApprovalRequest(tool: spec, argumentsJSON: "{}")
    }

    private func waitForCount(_ count: Int, in controller: ActionApprovalController) async throws {
        for _ in 0..<100 {
            if controller.pendingCount == count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Expected \(count) pending approvals, got \(controller.pendingCount)")
        throw ActionExecutionError.timedOut
    }

    func testConcurrentRequestsWaitInFIFOOrderInsteadOfAutoDenial() async throws {
        let controller = ActionApprovalController()
        defer { controller.cancelPending() }
        let requests = [request("first"), request("second"), request("third")]
        let first = Task { await controller.request(requests[0]) }
        try await waitForCount(1, in: controller)
        let second = Task { await controller.request(requests[1]) }
        try await waitForCount(2, in: controller)
        let third = Task { await controller.request(requests[2]) }
        try await waitForCount(3, in: controller)
        XCTAssertEqual(controller.pending?.id, requests[0].id)
        controller.resolve(.approve, requestID: requests[0].id)
        XCTAssertEqual(controller.pending?.id, requests[1].id)
        controller.resolve(.deny, requestID: requests[1].id)
        XCTAssertEqual(controller.pending?.id, requests[2].id)
        controller.resolve(.approve, requestID: requests[2].id)
        let decisions = await [first.value, second.value, third.value]
        XCTAssertEqual(decisions, [.approve, .deny, .approve])
        XCTAssertNil(controller.pending)
        XCTAssertEqual(controller.pendingCount, 0)
    }

    func testCancellingQueuedRequestLeavesOtherRequestsInOrder() async throws {
        let controller = ActionApprovalController()
        defer { controller.cancelPending() }
        let one = request("first")
        let two = request("second")
        let three = request("third")
        let first = Task { await controller.request(one) }
        try await waitForCount(1, in: controller)
        let second = Task { await controller.request(two) }
        try await waitForCount(2, in: controller)
        let third = Task { await controller.request(three) }
        try await waitForCount(3, in: controller)
        second.cancel()
        let cancelled = await second.value
        XCTAssertEqual(cancelled, .deny)
        XCTAssertEqual(controller.pendingCount, 2)
        XCTAssertEqual(controller.pending?.id, one.id)
        controller.resolve(.approve, requestID: one.id)
        XCTAssertEqual(controller.pending?.id, three.id)
        controller.resolve(.approve, requestID: three.id)
        let remaining = await [first.value, third.value]
        XCTAssertEqual(remaining, [.approve, .approve])
    }

    func testCancelledHeadPromotesNextAndStaleHUDResponseCannotApproveIt() async throws {
        let controller = ActionApprovalController()
        defer { controller.cancelPending() }
        let one = request("first")
        let two = request("second")
        let first = Task { await controller.request(one) }
        try await waitForCount(1, in: controller)
        let second = Task { await controller.request(two) }
        try await waitForCount(2, in: controller)
        first.cancel()
        let cancelled = await first.value
        XCTAssertEqual(cancelled, .deny)
        XCTAssertEqual(controller.pending?.id, two.id)
        controller.resolve(.approve, requestID: one.id)
        XCTAssertEqual(controller.pending?.id, two.id)
        controller.resolve(.approve, requestID: two.id)
        let approved = await second.value
        XCTAssertEqual(approved, .approve)
        controller.resolve(.approve, requestID: two.id)
        XCTAssertEqual(controller.pendingCount, 0)
    }

    func testSessionCancellationDrainsEveryContinuationAndAllowsNewRequests() async throws {
        let controller = ActionApprovalController()
        defer { controller.cancelPending() }
        let one = request("first")
        let two = request("second")
        let first = Task { await controller.request(one) }
        try await waitForCount(1, in: controller)
        let second = Task { await controller.request(two) }
        try await waitForCount(2, in: controller)
        controller.cancelPending()
        controller.cancelPending()
        let decisions = await [first.value, second.value]
        XCTAssertEqual(decisions, [.deny, .deny])
        XCTAssertNil(controller.pending)
        let nextRequest = request("new session")
        let next = Task { await controller.request(nextRequest) }
        try await waitForCount(1, in: controller)
        controller.resolve(.approve, requestID: nextRequest.id)
        let decision = await next.value
        XCTAssertEqual(decision, .approve)
    }

    func testAlreadyCancelledTaskNeverEnqueuesApproval() async {
        let controller = ActionApprovalController()
        defer { controller.cancelPending() }
        let pending = request("cancelled")
        let task = Task { await controller.request(pending) }
        task.cancel()
        let decision = await task.value
        XCTAssertEqual(decision, .deny)
        XCTAssertNil(controller.pending)
        XCTAssertEqual(controller.pendingCount, 0)
    }

    // MARK: Approve similar

    private func appRequest(_ name: String, app: String, risk: ActionToolRisk = .mutating, serverID: UUID = UUID()) -> ActionApprovalRequest {
        let spec = ActionToolSpec(descriptor: MCPToolDescriptor(serverID: serverID, serverName: "fixture", name: name,
            title: nil, description: nil, risk: risk, inputSchemaJSON: "{}"))
        return ActionApprovalRequest(tool: spec, argumentsJSON: #"{"app":"\#(app)","keys":["cmd","n"]}"#)
    }

    func testApproveSimilarApprovesAndGrantsTheSameToolForTheSameApp() async throws {
        let controller = ActionApprovalController()
        defer { controller.cancelPending() }
        let server = UUID()
        let first = appRequest("press_shortcut", app: "Notes", serverID: server)
        let task = Task { await controller.request(first) }
        try await waitForCount(1, in: controller)
        controller.approveSimilar(requestID: first.id)
        let decision = await task.value
        XCTAssertEqual(decision, .approve)
        XCTAssertEqual(controller.grants.count, 1)

        let again = appRequest("press_shortcut", app: "the Notes app", serverID: server)
        XCTAssertTrue(controller.isGranted(again.tool, argumentsJSON: #"{"app":"the Notes app","keys":["cmd","s"]}"#),
                      "Different keys, same tool and app: covered.")
        XCTAssertFalse(controller.isGranted(again.tool, argumentsJSON: #"{"app":"Pages","keys":["cmd","s"]}"#), "Another app is not covered.")
        let otherTool = appRequest("open_app", app: "Notes", serverID: server)
        XCTAssertFalse(controller.isGranted(otherTool.tool, argumentsJSON: #"{"name":"Notes"}"#), "Another tool is not covered.")
    }

    func testApproveSimilarOnAnUnsupportedCallJustApproves() async throws {
        let controller = ActionApprovalController()
        defer { controller.cancelPending() }
        let destructive = appRequest("kill_app", app: "Notes", risk: .destructive)
        let task = Task { await controller.request(destructive) }
        try await waitForCount(1, in: controller)
        controller.approveSimilar()
        let decision = await task.value
        XCTAssertEqual(decision, .approve)
        XCTAssertTrue(controller.grants.isEmpty, "Destructive tools never get a standing grant.")

        let noTarget = request("echo")
        let second = Task { await controller.request(noTarget) }
        try await waitForCount(1, in: controller)
        controller.approveSimilar(requestID: noTarget.id)
        _ = await second.value
        XCTAssertTrue(controller.grants.isEmpty, "A call that names no app or process cannot be generalised.")
    }

    func testApproveSimilarWithAStaleIDDoesNothing() async throws {
        let controller = ActionApprovalController()
        defer { controller.cancelPending() }
        let pending = appRequest("press_shortcut", app: "Notes")
        let task = Task { await controller.request(pending) }
        try await waitForCount(1, in: controller)
        controller.approveSimilar(requestID: UUID())
        XCTAssertEqual(controller.pendingCount, 1)
        XCTAssertTrue(controller.grants.isEmpty)
        controller.resolve(.deny, requestID: pending.id)
        _ = await task.value
    }

    // MARK: Plan cards

    private func plan(_ steps: [ActionPlanApprovalRequest.Route]) -> ActionPlanApprovalRequest {
        ActionPlanApprovalRequest(command: "test", steps: steps.enumerated().map { offset, route in
            .init(number: offset + 1, text: "step \(offset + 1)", summary: "summary \(offset + 1)", route: route)
        })
    }

    func testPlanApprovalPublishesTheCardAndApproveAllGrantsItsNativeSteps() async throws {
        let controller = ActionApprovalController()
        defer { controller.cancelPending() }
        let open = NativeOpenAction.openApp(name: "Notes")
        let shortcut = NativeOpenAction.pressShortcut(app: "Notes", shortcut: try XCTUnwrap(KeyboardShortcut(keys: ["cmd", "n"])))
        let request = plan([
            .alreadyDone,
            .native(spec: open.spec, argumentsJSON: try open.argumentsJSON()),
            .native(spec: shortcut.spec, argumentsJSON: try shortcut.argumentsJSON()),
            .planned
        ])
        let task = Task { await controller.requestPlan(request) }
        for _ in 0..<100 where controller.pendingPlan == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(controller.pendingPlan?.id, request.id)
        XCTAssertTrue(request.hasPlannedSteps)
        XCTAssertTrue(request.needsApproval(under: .readOnlyAuto))

        controller.resolvePlan(.approveAll, requestID: request.id)
        let decision = await task.value
        XCTAssertEqual(decision, .approveAll)
        XCTAssertNil(controller.pendingPlan)
        XCTAssertEqual(controller.grants.count, 2, "Only the two native steps become grants.")
        XCTAssertTrue(controller.isGranted(open.spec, argumentsJSON: try open.argumentsJSON()))
        XCTAssertTrue(controller.isGranted(shortcut.spec, argumentsJSON: #"{"keys":["cmd","n"],"app":"Notes"}"#), "Key order does not matter.")
        XCTAssertFalse(controller.isGranted(shortcut.spec, argumentsJSON: #"{"app":"Notes","keys":["cmd","s"]}"#), "Approving the plan does not approve other shortcuts.")
    }

    func testStepByStepAndDenyLeaveNoGrants() async throws {
        for decision in [ActionPlanApprovalDecision.stepByStep, .deny] {
            let controller = ActionApprovalController()
            defer { controller.cancelPending() }
            let open = NativeOpenAction.openApp(name: "Notes")
            let request = plan([.native(spec: open.spec, argumentsJSON: try open.argumentsJSON())])
            let task = Task { await controller.requestPlan(request) }
            for _ in 0..<100 where controller.pendingPlan == nil { try await Task.sleep(for: .milliseconds(5)) }
            controller.resolvePlan(decision)
            let result = await task.value
            XCTAssertEqual(result, decision)
            XCTAssertTrue(controller.grants.isEmpty)
            XCTAssertNil(controller.pendingPlan)
        }
    }

    func testPlanNeedsApprovalOnlyWhenAShownStepWouldAsk() throws {
        let readOnly = ActionToolSpec(descriptor: MCPToolDescriptor(serverID: UUID(), serverName: "fixture", name: "list_windows",
            title: nil, description: nil, risk: .readOnly, inputSchemaJSON: "{}"))
        XCTAssertFalse(plan([.alreadyDone, .planned]).needsApproval(under: .readOnlyAuto), "Nothing predictable to approve.")
        XCTAssertFalse(plan([.native(spec: readOnly, argumentsJSON: "{}")]).needsApproval(under: .readOnlyAuto))
        XCTAssertTrue(plan([.native(spec: readOnly, argumentsJSON: "{}")]).needsApproval(under: .alwaysAsk))
        let open = NativeOpenAction.openApp(name: "Notes")
        XCTAssertTrue(plan([.native(spec: open.spec, argumentsJSON: try open.argumentsJSON())]).needsApproval(under: .readOnlyAuto))
    }

    func testSecondPlanWhileOneIsPendingIsDeniedAndCancelPendingDeniesThePlan() async throws {
        let controller = ActionApprovalController()
        let first = plan([.planned])
        let task = Task { await controller.requestPlan(first) }
        for _ in 0..<100 where controller.pendingPlan == nil { try await Task.sleep(for: .milliseconds(5)) }
        let second = await controller.requestPlan(plan([.planned]))
        XCTAssertEqual(second, .deny)
        XCTAssertEqual(controller.pendingPlan?.id, first.id)

        controller.grant(.similar(toolID: "x", target: "app:notes"))
        controller.cancelPending()
        let decision = await task.value
        XCTAssertEqual(decision, .deny)
        XCTAssertNil(controller.pendingPlan)
        XCTAssertTrue(controller.grants.isEmpty, "Ending the command forgets its grants.")
    }

    func testCancellingThePlanTaskDeniesIt() async throws {
        let controller = ActionApprovalController()
        defer { controller.cancelPending() }
        let request = plan([.planned])
        let task = Task { await controller.requestPlan(request) }
        for _ in 0..<100 where controller.pendingPlan == nil { try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        let decision = await task.value
        XCTAssertEqual(decision, .deny)
        XCTAssertNil(controller.pendingPlan)
    }
}
