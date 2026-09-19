import XCTest
@testable import Superkeet

enum NativeGroundingFixture {
    static let window = NativeGroundingWindow(pid: 100, windowID: 42)
    static let windows = #"{"windows":[{"app_name":"Notes","pid":100,"window_id":42,"is_on_screen":true,"layer":0}]}"#

    static func tools() throws -> [ActionToolSpec] {
        let server = UUID()
        return try [
            ("list_windows", ["on_screen_only"]),
            ("get_window_state", ["pid", "window_id", "session", "include_screenshot"]),
            ("click", ["pid", "window_id", "session", "element_token"]),
            ("set_value", ["pid", "window_id", "session", "element_token", "value"])
        ].map { name, keys in
            let schema = try NativeGroundingJSON.encode([
                "type": "object", "properties": Dictionary(uniqueKeysWithValues: keys.map { ($0, ["type": "string"]) })
            ])
            return ActionToolSpec(descriptor: MCPToolDescriptor(
                serverID: server, serverName: "cua-driver", name: name, title: nil, description: nil,
                risk: name == "click" || name == "set_value" ? .mutating : .readOnly, inputSchemaJSON: schema
            ))
        }
    }

    static func row(_ index: Int, role: String = "AXTextField", label: String = "Title", parent: Int = 0,
                    snapshot: String = "s00000001", value: String = "") -> [String: Any] {
        ["element_index": index, "element_token": "\(snapshot):\(index)", "role": role, "label": label,
         "parent_index": parent, "enabled": true, "value": value, "actions": ["AXPress"]]
    }

    static func snapshot(_ sequence: Int = 1, value: String = "", rows: [[String: Any]]? = nil) throws -> String {
        let snapshot = String(format: "s%08x", sequence)
        let root: [String: Any] = ["role": "AXWindow", "depth": 0, "element_index": 0]
        return try NativeGroundingJSON.encode([
            "window_id": 42, "snapshot_id": snapshot,
            "elements": [root] + (rows ?? [row(1, snapshot: snapshot, value: value),
                                           row(2, role: "AXButton", label: "Save", snapshot: snapshot)])
        ])
    }

    static func parse(_ json: String) throws -> NativeGroundingSnapshot {
        try NativeGroundingSnapshot(json: json, window: window)
    }
}

final class NativeGroundingTests: XCTestCase {
    func testLiteralTemplatesPreserveExactTextAndRejectCompoundCommands() throws {
        let text = try XCTUnwrap(NativeActionStep.literal(#"Type "Hello and goodbye" into Title in Notes."#))
        XCTAssertEqual(text.app, "Notes")
        XCTAssertEqual(text.target, "Title")
        XCTAssertEqual(text.text, "Hello and goodbye")
        XCTAssertEqual(NativeActionStep.literal("Click Save in Notes")?.operation, .click)
        XCTAssertNil(NativeActionStep.literal("Click Save in Notes and open Safari"))
        XCTAssertNil(NativeActionStep.literal("Type Hello into Title in Notes"))
        XCTAssertNil(NativeActionStep.literal("Open Notes then click Save"))
        XCTAssertThrowsError(try NativeActionStep.decode(#"{"app":"Notes","target":"Title"}"#, operation: .setText))
        XCTAssertThrowsError(try NativeActionStep.decode(#"{"app":"Notes","target":"Save","pid":100}"#, operation: .click))
    }

    func testWindowSelectionRequiresOneExactVisibleApp() throws {
        XCTAssertEqual(try NativeGroundingWindow.resolve(NativeGroundingFixture.windows, app: "notes"), NativeGroundingFixture.window)
        XCTAssertThrowsError(try NativeGroundingWindow.resolve(NativeGroundingFixture.windows, app: "Note"))
        let duplicate = NativeGroundingFixture.windows.replacingOccurrences(of: "]}", with:
            #",{"app_name":"Notes","pid":100,"window_id":43,"is_on_screen":true,"layer":0}]}"#)
        XCTAssertThrowsError(try NativeGroundingWindow.resolve(duplicate, app: "Notes"))
        XCTAssertThrowsError(try NativeGroundingWindow.resolve(NativeGroundingFixture.windows.replacingOccurrences(of: "true", with: "false"), app: "Notes"))
    }

    func testCandidateUsesOnlyBoundCapabilityAndSuppliedValue() throws {
        let snapshot = try NativeGroundingFixture.parse(NativeGroundingFixture.snapshot())
        let tool = try XCTUnwrap(NativeGroundingTools(NativeGroundingFixture.tools())).setText
        let step = NativeActionStep(operation: .setText, app: "Notes", target: "Title", text: "literal \"value\"")
        let candidates = try snapshot.candidates(step: step, tool: tool, session: "owned")
        XCTAssertEqual(candidates.map(\.id), ["a0", "reobserve", "abstain"])
        let arguments = try NativeGroundingJSON.object(candidates[0].argumentsJSON)
        XCTAssertEqual(Set(arguments.keys), ["pid", "window_id", "element_token", "session", "value"])
        XCTAssertEqual(arguments["value"] as? String, step.text)
        XCTAssertEqual(arguments["element_token"] as? String, "s00000001:1")
        XCTAssertEqual(candidates[0].captureID, "ax:100:42:s00000001")
    }

    func testEligibilityExcludesWebDisabledUnlabeledAndUnrelatedControls() throws {
        var disabled = NativeGroundingFixture.row(4)
        disabled["enabled"] = false
        var secure = NativeGroundingFixture.row(5)
        secure["subrole"] = "AXSecureTextField"
        let rows = [NativeGroundingFixture.row(1, role: "AXWebArea"), NativeGroundingFixture.row(2, parent: 1),
                    NativeGroundingFixture.row(3, label: ""), disabled, secure,
                    NativeGroundingFixture.row(6, label: "Unrelated notes"), NativeGroundingFixture.row(7, parent: 999)]
        let snapshot = try NativeGroundingFixture.parse(NativeGroundingFixture.snapshot(rows: rows))
        let tool = try XCTUnwrap(NativeGroundingTools(NativeGroundingFixture.tools())).setText
        let step = NativeActionStep(operation: .setText, app: "Notes", target: "Title", text: "new")
        XCTAssertEqual(try snapshot.candidates(step: step, tool: tool, session: "test"), ActionCandidate.reserved)
    }

    func testSectionsAreIncludedAndDuplicateControlIdentityIsRejected() throws {
        let rows = [NativeGroundingFixture.row(1, role: "AXGroup", label: "Billing"),
                    NativeGroundingFixture.row(2, parent: 1), NativeGroundingFixture.row(3, parent: 1)]
        let snapshot = try NativeGroundingFixture.parse(NativeGroundingFixture.snapshot(rows: rows))
        let tool = try XCTUnwrap(NativeGroundingTools(NativeGroundingFixture.tools())).setText
        let step = NativeActionStep(operation: .setText, app: "Notes", target: "Title in Billing", text: "new")
        let candidates = try snapshot.candidates(step: step, tool: tool, session: "test")
        XCTAssertTrue(candidates[0].description.contains("Billing"))
        XCTAssertThrowsError(try snapshot.selectedElement(candidates[0]))
    }

    func testMalformedSnapshotsFailClosed() throws {
        let valid = try NativeGroundingFixture.snapshot()
        for (old, new) in [("\"window_id\":42", "\"window_id\":43"), ("s00000001", "stale") ] {
            XCTAssertThrowsError(try NativeGroundingFixture.parse(valid.replacingOccurrences(of: old, with: new)))
        }
        XCTAssertThrowsError(try NativeGroundingFixture.parse(NativeGroundingFixture.snapshot(rows: [
            NativeGroundingFixture.row(1), NativeGroundingFixture.row(1)
        ])))
        XCTAssertThrowsError(try NativeGroundingJSON.object(#"{"effect":"refused"}"#))
        XCTAssertThrowsError(try NativeGroundingJSON.object(String(repeating: " ", count: 1_048_577)))
        XCTAssertThrowsError(try NativeGroundingFixture.parse(valid.replacingOccurrences(of: "\"element_index\":1", with: "\"element_index\":true")))
        XCTAssertThrowsError(try NativeGroundingFixture.parse(valid.replacingOccurrences(of: "\"window_id\":42", with: "\"window_id\":42,\"truncated\":true")))
    }

    func testPostApprovalRefreshRenewsOnlyUnchangedApprovedControl() throws {
        let old = try NativeGroundingFixture.parse(NativeGroundingFixture.snapshot())
        let control = try XCTUnwrap(old.elements.first)
        let preflight = NativeActionPreflight(window: NativeGroundingFixture.window, session: "test", control: control, observationSchemaJSON: "{}")
        let arguments = #"{"element_token":"s00000001:1","value":"new"}"#
        let fresh = try NativeGroundingFixture.parse(NativeGroundingFixture.snapshot(2))
        let updated = try NativeGroundingJSON.object(preflight.refreshedArguments(arguments, snapshot: fresh))
        XCTAssertEqual(updated["element_token"] as? String, "s00000002:1")
        XCTAssertEqual(updated["value"] as? String, "new")
        XCTAssertThrowsError(try preflight.refreshedArguments(arguments, snapshot: old))
        let changed = try NativeGroundingFixture.parse(NativeGroundingFixture.snapshot(3, value: "user changed it"))
        XCTAssertThrowsError(try preflight.refreshedArguments(arguments, snapshot: changed))
    }

    func testApprovalRejectsCheckboxValueAndDocumentChanges() throws {
        var row = NativeGroundingFixture.row(1, role: "AXCheckBox", label: "Enabled")
        row["value"] = 0
        let old = try NativeGroundingFixture.parse(NativeGroundingFixture.snapshot(rows: [row]))
        let control = try XCTUnwrap(old.elements.first)
        let preflight = NativeActionPreflight(window: NativeGroundingFixture.window, session: "test", control: control, observationSchemaJSON: "{}")
        row["value"] = 1
        row["element_token"] = "s00000002:1"
        let changed = try NativeGroundingFixture.parse(NativeGroundingFixture.snapshot(2, rows: [row]))
        XCTAssertThrowsError(try preflight.refreshedArguments("{}", snapshot: changed))
        row["value"] = 0
        let newDocument = try NativeGroundingFixture.snapshot(2, rows: [row])
            .replacingOccurrences(of: "\"window_id\":42", with: "\"window_id\":42,\"window_title\":\"Another document\"")
        XCTAssertThrowsError(try preflight.refreshedArguments("{}", snapshot: NativeGroundingFixture.parse(newDocument)))
    }

    func testVerificationUsesControlIdentityAndActualReadback() throws {
        let control = try XCTUnwrap(NativeGroundingFixture.parse(NativeGroundingFixture.snapshot()).elements.first)
        let fresh = try NativeGroundingFixture.parse(NativeGroundingFixture.snapshot(2, value: "new"))
        XCTAssertTrue(fresh.verifies(text: "new", control: control))
        XCTAssertFalse(fresh.verifies(text: "different", control: control))
        let missing = try NativeGroundingFixture.parse(NativeGroundingFixture.snapshot(2, rows: []))
        XCTAssertFalse(missing.verifies(text: "new", control: control))
    }

    func testToolDiscoveryRequiresSameServerAndCapabilitySchemas() throws {
        let tools = try NativeGroundingFixture.tools()
        XCTAssertNotNil(NativeGroundingTools(tools))
        XCTAssertNil(NativeGroundingTools(Array(tools.dropLast())))
        XCTAssertNil(try NativeGroundingTools(tools + NativeGroundingFixture.tools()))
        let driver = try XCTUnwrap(NativeGroundingTools(tools))
        let ranked = ActionLimits.prioritizedTools(tools + driver.helpers, task: "Save my work")
        XCTAssertTrue(ranked.prefix(2).allSatisfy { $0.toolName.hasPrefix("superkeet_native_") })
    }
}
