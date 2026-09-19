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
        XCTFail("Expected approval before a native tool runs")
        throw ActionExecutionError.timedOut
    }

    func testNativeOpensSkipDefaultApprovalAndAreAuditedAsAutoApproved() async throws {
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
        defer { approvals.cancelPending() }
        let executor = Executor()
        let router = ActionToolRouter(approvals: approvals, audit: audit, settings: settings, callTool: { _, _, _, _ in
            XCTFail("Native opens must not call MCP")
            return "unexpected"
        }, nativeExecutor: executor)
        let examples: [(NativeOpenAction, String)] = [
            (.openApp(name: "Discord"), #"{"name":"Discord"}"#),
            (.openURL(url: try XCTUnwrap(URL(string: "https://youtube.com")), browser: "Helium"), #"{"url":"youtube.com","browser":"Helium"}"#)
        ]
        for (action, arguments) in examples {
            let result = try await AsyncTimeout.run(seconds: 1, timeoutError: ActionExecutionError.timedOut) {
                try await router.execute(spec: action.spec, argumentsJSON: arguments)
            }
            XCTAssertEqual(result, "Opened by native fixture.")
            XCTAssertNil(approvals.pending, "Exempt opens never reach the approval HUD.")
            XCTAssertEqual(approvals.pendingCount, 0)
        }
        XCTAssertEqual(executor.actions, examples.map { $0.0 })
        let entries = audit.entries()
        XCTAssertEqual(entries.map(\.toolName), ["open_app", "open_url"])
        XCTAssertTrue(entries.allSatisfy { $0.serverName == "superkeet" && $0.risk == "mutating" })
        XCTAssertEqual(entries.map(\.outcome), ["succeeded (auto-approved)", "succeeded (auto-approved)"])
        let urlEntry = try XCTUnwrap(entries.last)
        let urlArguments = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(urlEntry.arguments.utf8)) as? [String: String])
        XCTAssertEqual(urlArguments["url"], "https://youtube.com")
        XCTAssertEqual(urlArguments["browser"], "Helium")
    }

    func testAlwaysAskRequiresApprovalForEveryNativeToolAndRecordsAudit() async throws {
        let settings = AppSettings.shared
        let policy = settings.actionApprovalPolicy
        let auditEnabled = settings.actionAuditEnabled
        settings.actionApprovalPolicy = .alwaysAsk
        settings.actionAuditEnabled = true
        defer { settings.actionApprovalPolicy = policy; settings.actionAuditEnabled = auditEnabled }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        defer { try? FileManager.default.removeItem(at: file) }
        let audit = ActionAuditStore(fileURL: file)
        let approvals = ActionApprovalController()
        defer { approvals.cancelPending() }
        let executor = Executor()
        let router = ActionToolRouter(approvals: approvals, audit: audit, settings: settings, nativeExecutor: executor)
        let actions: [NativeOpenAction] = [
            .openApp(name: "Notes"),
            .openURL(url: try XCTUnwrap(URL(string: "https://example.com")), browser: nil),
            .pressShortcut(app: "Notes", shortcut: try XCTUnwrap(KeyboardShortcut(keys: ["cmd", "n"])))
        ]
        for (index, action) in actions.enumerated() {
            let arguments = try action.argumentsJSON()
            let task = Task { try await router.execute(spec: action.spec, argumentsJSON: arguments) }
            defer { task.cancel() }
            try await waitForApproval(approvals)
            XCTAssertEqual(executor.actions.count, index, "Each tool must wait for approval.")
            let pending = try XCTUnwrap(approvals.pending)
            XCTAssertEqual(pending.tool, action.spec)
            XCTAssertEqual(pending.argumentsJSON, arguments)
            approvals.resolve(.approve, requestID: pending.id)
            let result = try await task.value
            XCTAssertEqual(result, "Opened by native fixture.")
        }
        XCTAssertEqual(executor.actions, actions)
        XCTAssertEqual(audit.entries().map(\.outcome), ["succeeded", "succeeded", "succeeded"])
    }

    func testNativeShortcutRiskAndApprovalExemptionCannotBeForged() async throws {
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
            defer { approvals.cancelPending() }
            let executor = Executor()
            let router = ActionToolRouter(approvals: approvals, audit: audit, settings: settings, nativeExecutor: executor)
            var forged = ActionToolSpec(descriptor: MCPToolDescriptor(serverID: NativeActionExecutor.serverID, serverName: "fake",
                name: "press_shortcut", title: nil, description: nil, risk: .readOnly, inputSchemaJSON: "{}"))
            forged.approvalExempt = true
            let task = Task { try await router.execute(spec: forged, argumentsJSON: #"{"app":"Notes","keys":["cmd","n"]}"#) }
            defer { task.cancel() }
            try await waitForApproval(approvals)
            XCTAssertEqual(approvals.pending?.tool, NativeOpenAction.tools[2])
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
        settings.actionApprovalPolicy = .alwaysAsk
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

        let task = Task { try await router.execute(spec: spec, argumentsJSON: #"{"name":"Pages"}"#) }
        try await waitForApproval(approvals)
        approvals.resolve(.deny)
        do { _ = try await task.value; XCTFail("Expected denial") } catch { }
        XCTAssertEqual(audit.entries().map(\.outcome), ["succeeded (pre-approved)", "denied"])

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

    func testExemptNativeDispatchFailureIsAuditedOnce() async throws {
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
        defer { approvals.cancelPending() }
        let executor = Executor()
        executor.failure = NativeOpenActionError.openFailed("fixture failure")
        let router = ActionToolRouter(approvals: approvals, audit: audit, settings: settings, nativeExecutor: executor)
        do {
            _ = try await AsyncTimeout.run(seconds: 1, timeoutError: ActionExecutionError.timedOut) {
                try await router.execute(spec: NativeOpenAction.tools[0], argumentsJSON: #"{"name":"Discord"}"#)
            }
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(error as? NativeOpenActionError, .openFailed("fixture failure"))
        }
        XCTAssertNil(approvals.pending)
        XCTAssertEqual(executor.actions.count, 1)
        XCTAssertEqual(audit.entries().map(\.outcome), ["failed"])
    }
}
