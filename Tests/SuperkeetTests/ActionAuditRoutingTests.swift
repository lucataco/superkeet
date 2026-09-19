import XCTest
@testable import Superkeet

@MainActor
final class ActionAuditRoutingTests: XCTestCase {
    func testAutoApproveSkipsPromptsAndLabelsOnlyStateChanges() async throws {
        let settings = AppSettings.shared
        let policy = settings.actionApprovalPolicy
        let enabled = settings.actionAuditEnabled
        settings.actionApprovalPolicy = .autoApprove
        settings.actionAuditEnabled = true
        defer { settings.actionApprovalPolicy = policy; settings.actionAuditEnabled = enabled }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        defer { try? FileManager.default.removeItem(at: file) }
        let audit = ActionAuditStore(fileURL: file)
        let approvals = ActionApprovalController()
        defer { approvals.cancelPending() }
        let router = ActionToolRouter(approvals: approvals, audit: audit, settings: settings, callTool: { _, _, _, _ in "done" })

        for risk in [ActionToolRisk.readOnly, .mutating] {
            let spec = ActionToolSpec(descriptor: MCPToolDescriptor(serverID: UUID(), serverName: "fixture", name: risk.rawValue,
                title: nil, description: nil, risk: risk, inputSchemaJSON: "{}"))
            let output = try await AsyncTimeout.run(seconds: 1, timeoutError: ActionExecutionError.timedOut) {
                try await router.execute(spec: spec, argumentsJSON: "{}")
            }
            XCTAssertEqual(output, "done")
            XCTAssertNil(approvals.pending)
            XCTAssertEqual(approvals.pendingCount, 0)
        }

        let entries = audit.entries()
        XCTAssertEqual(entries.map(\.risk), ["readOnly", "mutating"])
        XCTAssertEqual(entries.map(\.outcome), ["succeeded", "succeeded (auto-approved)"])
    }

    func testAutoApproveDestructiveToolsStillWaitForApprovalAndHonorDenial() async throws {
        let settings = AppSettings.shared
        let policy = settings.actionApprovalPolicy
        let enabled = settings.actionAuditEnabled
        settings.actionApprovalPolicy = .autoApprove
        settings.actionAuditEnabled = true
        defer { settings.actionApprovalPolicy = policy; settings.actionAuditEnabled = enabled }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        defer { try? FileManager.default.removeItem(at: file) }
        let audit = ActionAuditStore(fileURL: file)
        let approvals = ActionApprovalController()
        defer { approvals.cancelPending() }
        let calls = OSAllocatedUnfairLockBox<Int>(0)
        let router = ActionToolRouter(approvals: approvals, audit: audit, settings: settings, callTool: { _, _, _, _ in
            calls.mutate { $0 += 1 }
            return "done"
        })
        let spec = ActionToolSpec(descriptor: MCPToolDescriptor(serverID: UUID(), serverName: "fixture", name: "delete_file",
            title: nil, description: nil, risk: .destructive, inputSchemaJSON: "{}"))

        for decision in [ActionApprovalDecision.deny, .approve] {
            let task = Task { try await router.execute(spec: spec, argumentsJSON: "{}") }
            defer { task.cancel() }
            for _ in 0..<100 where approvals.pending == nil { try await Task.sleep(for: .milliseconds(5)) }
            let pending = try XCTUnwrap(approvals.pending)
            XCTAssertEqual(pending.tool, spec)
            XCTAssertEqual(calls.value, 0, "Destructive calls must wait for approval.")
            approvals.resolve(decision, requestID: pending.id)
            do {
                let output = try await task.value
                XCTAssertEqual(decision, .approve)
                XCTAssertEqual(output, "done")
            } catch {
                XCTAssertEqual(decision, .deny)
                XCTAssertEqual(error as? ActionExecutionError, .approvalDenied(spec.displayName))
            }
        }

        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(audit.entries().map(\.outcome), ["denied", "succeeded"])
    }

    func testRouterAuditKeepsTitlesAndQueriesButMasksSecrets() async throws {
        let settings = AppSettings.shared
        let policy = settings.actionApprovalPolicy
        let enabled = settings.actionAuditEnabled
        settings.actionApprovalPolicy = .readOnlyAuto
        settings.actionAuditEnabled = true
        defer { settings.actionApprovalPolicy = policy; settings.actionAuditEnabled = enabled }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        defer { try? FileManager.default.removeItem(at: file) }
        let audit = ActionAuditStore(fileURL: file)
        let router = ActionToolRouter(audit: audit, settings: settings, callTool: { _, _, _, _ in "ordinary tool result" })
        let spec = ActionToolSpec(descriptor: MCPToolDescriptor(serverID: UUID(), serverName: "fixture", name: "get_state",
            title: nil, description: nil, risk: .readOnly, inputSchemaJSON: "{}"))
        let arguments = #"{"title":"DNS records","query":"catacolabs.com","api_key":"fixture-secret"}"#
        _ = try await router.execute(spec: spec, argumentsJSON: arguments)
        let entry = try XCTUnwrap(audit.entries().first)
        XCTAssertTrue(entry.arguments.contains("catacolabs.com"))
        XCTAssertTrue(entry.arguments.contains("DNS records"))
        XCTAssertFalse(entry.arguments.contains("fixture-secret"))
        XCTAssertEqual(entry.detail, "ordinary tool result")
    }

    func testCompactObservationRequestsStructuredContentSkipsScreenshotsAndReturnsItWhole() async throws {
        let settings = AppSettings.shared
        let policy = settings.actionApprovalPolicy
        let enabled = settings.actionAuditEnabled
        settings.actionApprovalPolicy = .readOnlyAuto
        settings.actionAuditEnabled = true
        defer { settings.actionApprovalPolicy = policy; settings.actionAuditEnabled = enabled }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        defer { try? FileManager.default.removeItem(at: file) }
        let audit = ActionAuditStore(fileURL: file)
        let calls = OSAllocatedUnfairLockBox<[(String, Bool)]>([])
        let big = #"{"snapshot_id":"s00000001","elements":[],"padding":""# + String(repeating: "x", count: 3_000) + #""}"#
        let router = ActionToolRouter(audit: audit, settings: settings, callTool: { _, _, arguments, structured in
            calls.mutate { $0.append((arguments, structured)) }
            return structured ? big : "text only"
        })
        let schema = #"{"type":"object","properties":{"pid":{"type":"integer"},"window_id":{"type":"integer"},"include_screenshot":{"type":"boolean"}}}"#
        var spec = ActionToolSpec(descriptor: MCPToolDescriptor(serverID: UUID(), serverName: "cua-driver", name: "get_window_state",
            title: nil, description: nil, risk: .readOnly, inputSchemaJSON: schema))
        spec.compactObservation = true
        spec.requiresFreshObservation = true

        let output = try await router.execute(spec: spec, argumentsJSON: #"{"pid":1,"window_id":2}"#)
        XCTAssertEqual(output, big, "The whole observation comes back so the controller can project it before truncating.")
        XCTAssertEqual(calls.value.first?.0, #"{"include_screenshot":false,"pid":1,"window_id":2}"#, "The tree-only form is requested by default.")
        XCTAssertEqual(calls.value.first?.1, true)

        _ = try await router.execute(spec: spec, argumentsJSON: #"{"pid":1,"window_id":2,"include_screenshot":true}"#)
        XCTAssertEqual(calls.value.last?.0, #"{"pid":1,"window_id":2,"include_screenshot":true}"#, "An explicit choice is respected.")

        let entries = audit.entries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries.allSatisfy { $0.outcome == "succeeded" && $0.detail == nil }, "Observation contents stay out of the audit log.")
    }

    func testObservationDefaultsOnlyApplyWhenTheSchemaOffersAScreenshot() {
        let withOption = #"{"type":"object","properties":{"include_screenshot":{"type":"boolean"}}}"#
        XCTAssertEqual(ActionArgumentNormalizer.applyingObservationDefaults(argumentsJSON: "{}", schemaJSON: withOption), #"{"include_screenshot":false}"#)
        XCTAssertEqual(ActionArgumentNormalizer.applyingObservationDefaults(argumentsJSON: "", schemaJSON: withOption), #"{"include_screenshot":false}"#)
        XCTAssertEqual(ActionArgumentNormalizer.applyingObservationDefaults(argumentsJSON: #"{"pid":3}"#, schemaJSON: #"{"type":"object","properties":{"pid":{}}}"#), #"{"pid":3}"#)
        XCTAssertEqual(ActionArgumentNormalizer.applyingObservationDefaults(argumentsJSON: "not json", schemaJSON: withOption), "not json")
    }
}
