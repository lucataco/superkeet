import XCTest
@testable import Superkeet

@MainActor
final class NativeGroundingRouterTests: XCTestCase {
    actor Transport {
        private(set) var calls: [(String, String, Bool)] = []
        let changed: Bool
        init(changed: Bool = false) { self.changed = changed }
        func call(_ id: UUID, _ name: String, _ json: String, _ structured: Bool) throws -> String {
            calls.append((name, json, structured))
            if name == "get_window_state" {
                return try NativeGroundingFixture.snapshot(2, value: changed ? "changed by user" : "")
            }
            return #"{"effect":"confirmed","value":"private output"}"#
        }
    }

    private func spec() throws -> ActionToolSpec {
        let driver = try XCTUnwrap(NativeGroundingTools(NativeGroundingFixture.tools()))
        let snapshot = try NativeGroundingFixture.parse(NativeGroundingFixture.snapshot())
        let control = try XCTUnwrap(snapshot.elements.first)
        var spec = driver.setText
        spec.nativePreflight = NativeActionPreflight(window: NativeGroundingFixture.window, session: "owned", control: control,
                                                    observationSchemaJSON: driver.observe.inputSchemaJSON)
        spec.groundingDecision = .init(selectedID: "a0", confidence: 0.99, decisionMilliseconds: 30)
        spec.approvalSummary = "Replace Title in Notes"
        return spec
    }

    private func waitForApproval(_ approvals: ActionApprovalController) async throws {
        for _ in 0..<100 {
            if approvals.pending != nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected pending approval")
        throw ActionExecutionError.timedOut
    }

    func testApprovalPrecedesFreshObservationAndUsesRenewedTokenWithAudit() async throws {
        let settings = AppSettings.shared
        let policy = settings.actionApprovalPolicy
        let auditEnabled = settings.actionAuditEnabled
        settings.actionApprovalPolicy = .readOnlyAuto
        settings.actionAuditEnabled = true
        defer { settings.actionApprovalPolicy = policy; settings.actionAuditEnabled = auditEnabled }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        defer { try? FileManager.default.removeItem(at: url) }
        let audit = ActionAuditStore(fileURL: url)
        let approvals = ActionApprovalController()
        let transport = Transport()
        let router = ActionToolRouter(approvals: approvals, audit: audit, settings: settings,
                                      callTool: { try await transport.call($0, $1, $2, $3) })
        let spec = try spec()
        let task = Task {
            try await router.execute(spec: spec, argumentsJSON: #"{"pid":100,"window_id":42,"element_token":"s00000001:1","value":"private entry","session":"owned"}"#)
        }
        try await waitForApproval(approvals)
        let before = await transport.calls
        XCTAssertTrue(before.isEmpty)
        XCTAssertEqual(approvals.pending?.tool.approvalSummary, "Replace Title in Notes")
        approvals.resolve(.approve)
        _ = try await task.value
        let calls = await transport.calls
        XCTAssertEqual(calls.map { $0.0 }, ["get_window_state", "set_value"])
        XCTAssertTrue(calls.allSatisfy { $0.2 })
        let sent = try NativeGroundingJSON.object(calls[1].1)
        XCTAssertEqual(sent["element_token"] as? String, "s00000002:1")
        XCTAssertEqual(sent["value"] as? String, "private entry")
        let entries = audit.entries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.last?.grounding, spec.groundingDecision)
        XCTAssertTrue(entries.allSatisfy { $0.detail == nil && !$0.arguments.contains("private") && !$0.arguments.contains("s000000") })
    }

    func testDeniedOrCancelledApprovalNeverReachesDriver() async throws {
        let settings = AppSettings.shared
        let policy = settings.actionApprovalPolicy
        settings.actionApprovalPolicy = .readOnlyAuto
        defer { settings.actionApprovalPolicy = policy }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        defer { try? FileManager.default.removeItem(at: url) }
        for cancel in [false, true] {
            let approvals = ActionApprovalController()
            let transport = Transport()
            let router = ActionToolRouter(approvals: approvals, audit: ActionAuditStore(fileURL: url), settings: settings,
                                          callTool: { try await transport.call($0, $1, $2, $3) })
            let spec = try spec()
            let task = Task { try await router.execute(spec: spec, argumentsJSON: "{}") }
            try await waitForApproval(approvals)
            if cancel { task.cancel() }
            approvals.resolve(cancel ? .approve : .deny)
            do { _ = try await task.value; XCTFail("Expected denied or cancelled") } catch { }
            let calls = await transport.calls
            XCTAssertTrue(calls.isEmpty)
        }
    }

    func testChangedControlAfterApprovalDoesNotRunMutation() async throws {
        let settings = AppSettings.shared
        let policy = settings.actionApprovalPolicy
        settings.actionApprovalPolicy = .readOnlyAuto
        defer { settings.actionApprovalPolicy = policy }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        defer { try? FileManager.default.removeItem(at: url) }
        let approvals = ActionApprovalController()
        let transport = Transport(changed: true)
        let router = ActionToolRouter(approvals: approvals, audit: ActionAuditStore(fileURL: url), settings: settings,
                                      callTool: { try await transport.call($0, $1, $2, $3) })
        let spec = try spec()
        let task = Task { try await router.execute(spec: spec, argumentsJSON: "{}") }
        try await waitForApproval(approvals)
        approvals.resolve(.approve)
        do { _ = try await task.value; XCTFail("Expected changed target rejection") } catch { XCTAssertTrue(error is ActionChoiceError) }
        let calls = await transport.calls
        XCTAssertEqual(calls.map { $0.0 }, ["get_window_state"])
    }
}
