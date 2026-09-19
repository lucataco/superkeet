import XCTest
@testable import Superkeet

@MainActor
final class NativeOpenRouterTests: XCTestCase {
    final class Executor: NativeActionExecuting {
        private(set) var actions: [NativeOpenAction] = []
        var failure: Error?
        func execute(_ action: NativeOpenAction) async throws -> String {
            actions.append(action)
            if let failure { throw failure }
            return "Opened by native fixture."
        }
    }

    private func waitForApproval(_ approvals: ActionApprovalController) async throws {
        for _ in 0..<100 {
            if approvals.pending != nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected approval before a native open")
        throw ActionExecutionError.timedOut
    }

    func testNativeOpenRunsOnlyAfterApprovalAndRecordsAudit() async throws {
        let settings = AppSettings.shared
        let policy = settings.actionApprovalPolicy
        let auditEnabled = settings.actionAuditEnabled
        settings.actionApprovalPolicy = .readOnlyAuto
        settings.actionAuditEnabled = true
        defer { settings.actionApprovalPolicy = policy; settings.actionAuditEnabled = auditEnabled }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        defer { try? FileManager.default.removeItem(at: file) }
        let audit = ActionAuditStore(fileURL: file)
        let approvals = ActionApprovalController()
        let executor = Executor()
        let router = ActionToolRouter(approvals: approvals, audit: audit, settings: settings, callTool: { _, _, _, _ in
            XCTFail("Native opens must not call MCP")
            return "unexpected"
        }, nativeExecutor: executor)
        let spec = NativeOpenAction.tools[1]
        let task = Task { try await router.execute(spec: spec, argumentsJSON: #"{"url":"youtube.com","browser":"Helium"}"#) }
        try await waitForApproval(approvals)
        XCTAssertTrue(executor.actions.isEmpty)
        let pending = try XCTUnwrap(approvals.pending)
        XCTAssertEqual(try NativeOpenAction.decode(toolName: pending.tool.toolName, argumentsJSON: pending.argumentsJSON),
                       .openURL(url: try XCTUnwrap(URL(string: "https://youtube.com")), browser: "Helium"))
        approvals.resolve(.approve)
        let result = try await task.value
        XCTAssertEqual(result, "Opened by native fixture.")
        XCTAssertEqual(executor.actions, [.openURL(url: try XCTUnwrap(URL(string: "https://youtube.com")), browser: "Helium")])
        let entry = try XCTUnwrap(audit.entries().first)
        XCTAssertEqual(entry.serverName, "superkeet")
        XCTAssertEqual(entry.toolName, "open_url")
        XCTAssertEqual(entry.risk, "mutating")
        XCTAssertEqual(entry.outcome, "succeeded")
        XCTAssertTrue(entry.arguments.contains("Helium"))
    }

    func testNativeToolRiskCannotBeDowngradedAndDenialOrCancellationPreventsExecution() async throws {
        let settings = AppSettings.shared
        let policy = settings.actionApprovalPolicy
        let auditEnabled = settings.actionAuditEnabled
        settings.actionApprovalPolicy = .readOnlyAuto
        settings.actionAuditEnabled = true
        defer { settings.actionApprovalPolicy = policy; settings.actionAuditEnabled = auditEnabled }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        defer { try? FileManager.default.removeItem(at: file) }
        let audit = ActionAuditStore(fileURL: file)
        for cancel in [false, true] {
            let approvals = ActionApprovalController()
            let executor = Executor()
            let router = ActionToolRouter(approvals: approvals, audit: audit, settings: settings, nativeExecutor: executor)
            let forged = ActionToolSpec(descriptor: MCPToolDescriptor(serverID: NativeActionExecutor.serverID, serverName: "fake",
                name: "open_app", title: nil, description: nil, risk: .readOnly, inputSchemaJSON: "{}"))
            let task = Task { try await router.execute(spec: forged, argumentsJSON: #"{"name":"Discord"}"#) }
            try await waitForApproval(approvals)
            XCTAssertEqual(approvals.pending?.tool, NativeOpenAction.tools[0])
            if cancel { task.cancel() }
            approvals.resolve(cancel ? .approve : .deny)
            do { _ = try await task.value; XCTFail("Expected denial or cancellation") } catch { }
            XCTAssertTrue(executor.actions.isEmpty)
        }
        XCTAssertEqual(audit.entries().map(\.outcome), ["denied", "cancelled"])
    }

    func testGrantedCallsSkipTheApprovalQueueAndAreAuditedAsPreapproved() async throws {
        let settings = AppSettings.shared
        let policy = settings.actionApprovalPolicy
        let auditEnabled = settings.actionAuditEnabled
        settings.actionApprovalPolicy = .readOnlyAuto
        settings.actionAuditEnabled = true
        defer { settings.actionApprovalPolicy = policy; settings.actionAuditEnabled = auditEnabled }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        defer { try? FileManager.default.removeItem(at: file) }
        let audit = ActionAuditStore(fileURL: file)
        let approvals = ActionApprovalController()
        let executor = Executor()
        let router = ActionToolRouter(approvals: approvals, audit: audit, settings: settings, nativeExecutor: executor)
        let spec = NativeOpenAction.tools[0]

        approvals.grant(.exact(for: spec, argumentsJSON: #"{"name":"Notes"}"#))
        let output = try await router.execute(spec: spec, argumentsJSON: #"{"name":"Notes"}"#)
        XCTAssertEqual(output, "Opened by native fixture.")
        XCTAssertNil(approvals.pending, "A granted call never reaches the HUD.")
        XCTAssertEqual(executor.actions, [.openApp(name: "Notes")])
        XCTAssertEqual(audit.entries().map(\.outcome), ["succeeded (pre-approved)"])

        // A different app is not covered and asks as usual.
        let task = Task { try await router.execute(spec: spec, argumentsJSON: #"{"name":"Pages"}"#) }
        try await waitForApproval(approvals)
        approvals.resolve(.deny)
        do { _ = try await task.value; XCTFail("Expected denial") } catch { }
        XCTAssertEqual(audit.entries().map(\.outcome), ["succeeded (pre-approved)", "denied"])

        // Ending the session forgets the grant.
        router.cancelPendingApprovals()
        let again = Task { try await router.execute(spec: spec, argumentsJSON: #"{"name":"Notes"}"#) }
        try await waitForApproval(approvals)
        approvals.resolve(.approve)
        _ = try await again.value
        XCTAssertEqual(audit.entries().last?.outcome, "succeeded")
    }

    func testPlanApprovalIsForwardedAndAudited() async throws {
        let settings = AppSettings.shared
        let auditEnabled = settings.actionAuditEnabled
        settings.actionAuditEnabled = true
        defer { settings.actionAuditEnabled = auditEnabled }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        defer { try? FileManager.default.removeItem(at: file) }
        let audit = ActionAuditStore(fileURL: file)
        let approvals = ActionApprovalController()
        let router = ActionToolRouter(approvals: approvals, audit: audit, settings: settings, nativeExecutor: Executor())
        let open = NativeOpenAction.openApp(name: "Notes")
        let plan = ActionPlanApprovalRequest(command: "open Notes and create a new note", steps: [
            .init(number: 1, text: "open Notes", summary: "Open Notes", route: .native(spec: open.spec, argumentsJSON: try open.argumentsJSON())),
            .init(number: 2, text: "create a new note", summary: "Press ⌘N in Notes", route: .planned)
        ])
        let task = Task { await router.requestPlanApproval(plan) }
        for _ in 0..<100 where approvals.pendingPlan == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(approvals.pendingPlan?.id, plan.id)
        approvals.resolvePlan(.approveAll, requestID: plan.id)
        let decision = await task.value
        XCTAssertEqual(decision, .approveAll)
        XCTAssertTrue(approvals.isGranted(open.spec, argumentsJSON: try open.argumentsJSON()))
        let entry = try XCTUnwrap(audit.entries().first)
        XCTAssertEqual(entry.toolName, "plan")
        XCTAssertEqual(entry.outcome, "plan approved")
        XCTAssertTrue(entry.arguments.contains("Open Notes"))
        XCTAssertTrue(entry.arguments.contains("Press"))
    }

    func testNativeDispatchFailureIsAuditedOnce() async throws {
        let settings = AppSettings.shared
        let policy = settings.actionApprovalPolicy
        let auditEnabled = settings.actionAuditEnabled
        settings.actionApprovalPolicy = .readOnlyAuto
        settings.actionAuditEnabled = true
        defer { settings.actionApprovalPolicy = policy; settings.actionAuditEnabled = auditEnabled }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        defer { try? FileManager.default.removeItem(at: file) }
        let audit = ActionAuditStore(fileURL: file)
        let approvals = ActionApprovalController()
        let executor = Executor()
        executor.failure = NativeOpenActionError.openFailed("fixture failure")
        let router = ActionToolRouter(approvals: approvals, audit: audit, settings: settings, nativeExecutor: executor)
        let task = Task { try await router.execute(spec: NativeOpenAction.tools[0], argumentsJSON: #"{"name":"Discord"}"#) }
        try await waitForApproval(approvals)
        approvals.resolve(.approve)
        do { _ = try await task.value; XCTFail("Expected failure") } catch { XCTAssertEqual(error as? NativeOpenActionError, .openFailed("fixture failure")) }
        XCTAssertEqual(executor.actions.count, 1)
        XCTAssertEqual(audit.entries().map(\.outcome), ["failed"])
    }
}
