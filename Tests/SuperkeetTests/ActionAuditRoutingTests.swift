import XCTest
@testable import Superkeet

@MainActor
final class ActionAuditRoutingTests: XCTestCase {
    func testRouterSelectsGroundingRedactionOnlyForUIBoundCalls() async throws {
        let settings = AppSettings.shared
        let policy = settings.actionApprovalPolicy
        let enabled = settings.actionAuditEnabled
        settings.actionApprovalPolicy = .readOnlyAuto
        settings.actionAuditEnabled = true
        defer { settings.actionApprovalPolicy = policy; settings.actionAuditEnabled = enabled }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        defer { try? FileManager.default.removeItem(at: file) }
        let audit = ActionAuditStore(fileURL: file)
        let router = ActionToolRouter(audit: audit, settings: settings, callTool: { _, _, _, structured in
            structured ? #"{"status":"ok"}"# : "ordinary tool result"
        })
        var spec = ActionToolSpec(descriptor: MCPToolDescriptor(serverID: UUID(), serverName: "fixture", name: "get_state",
            title: nil, description: nil, risk: .readOnly, inputSchemaJSON: "{}"))
        let arguments = #"{"title":"DNS records","query":"catacolabs.com","api_key":"fixture-secret"}"#
        _ = try await router.execute(spec: spec, argumentsJSON: arguments)
        spec.nativeObservation = true
        _ = try await router.execute(spec: spec, argumentsJSON: arguments)
        let entries = audit.entries()
        guard entries.count == 2 else { return XCTFail("Expected one generic and one UI observation audit entry") }
        XCTAssertTrue(entries[0].arguments.contains("catacolabs.com"))
        XCTAssertTrue(entries[0].arguments.contains("DNS records"))
        XCTAssertEqual(entries[0].detail, "ordinary tool result")
        XCTAssertFalse(entries[1].arguments.contains("catacolabs.com"))
        XCTAssertFalse(entries[1].arguments.contains("DNS records"))
        XCTAssertNil(entries[1].detail)
        XCTAssertTrue(entries.allSatisfy { !$0.arguments.contains("fixture-secret") })
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
