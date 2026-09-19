import XCTest
@testable import Superkeet

final class ActionApprovalGrantTests: XCTestCase {
    private func spec(_ name: String, risk: ActionToolRisk = .mutating, server: UUID = UUID()) -> ActionToolSpec {
        ActionToolSpec(descriptor: MCPToolDescriptor(serverID: server, serverName: "cua-driver", name: name, title: nil,
                                                     description: nil, risk: risk, inputSchemaJSON: "{}"))
    }

    func testTargetIsDerivedFromAppProcessBundleOrPage() {
        let click = spec("click")
        XCTAssertEqual(ActionApprovalGrant.target(of: click, argumentsJSON: #"{"pid":4242,"element_token":"s1:3"}"#), "pid:4242")
        XCTAssertEqual(ActionApprovalGrant.target(of: click, argumentsJSON: #"{"app":"The Notes App"}"#), "app:notes")
        XCTAssertEqual(ActionApprovalGrant.target(of: click, argumentsJSON: #"{"browser":"Google Chrome","url":"https://x.com"}"#), "app:google chrome")
        XCTAssertEqual(ActionApprovalGrant.target(of: click, argumentsJSON: #"{"bundle_id":"com.apple.Notes"}"#), "bundle:com.apple.Notes")
        XCTAssertEqual(ActionApprovalGrant.target(of: click, argumentsJSON: #"{"pageId":7,"uid":"1_3"}"#), "page:7")
        XCTAssertNil(ActionApprovalGrant.target(of: click, argumentsJSON: #"{"x":1,"y":2}"#))
        XCTAssertNil(ActionApprovalGrant.target(of: click, argumentsJSON: "not json"))
        XCTAssertNil(ActionApprovalGrant.target(of: click, argumentsJSON: #"{"app":"  "}"#))
    }

    func testSimilarGrantCoversSameToolAndTargetButNeverDestructiveTools() {
        let server = UUID()
        let click = spec("click", server: server)
        let grant = ActionApprovalGrant.similar(to: click, argumentsJSON: #"{"pid":42,"element_token":"a"}"#)
        XCTAssertTrue(grant.covers(click, argumentsJSON: #"{"pid":42,"element_token":"b"}"#))
        XCTAssertFalse(grant.covers(click, argumentsJSON: #"{"pid":43,"element_token":"b"}"#))
        XCTAssertFalse(grant.covers(spec("type_text", server: server), argumentsJSON: #"{"pid":42}"#))
        XCTAssertFalse(grant.covers(spec("click", server: UUID()), argumentsJSON: #"{"pid":42}"#), "Same name on another server is another tool.")

        let kill = spec("kill_app", risk: .destructive, server: server)
        let killGrant = ActionApprovalGrant.similar(to: kill, argumentsJSON: #"{"pid":42}"#)
        XCTAssertFalse(killGrant.covers(kill, argumentsJSON: #"{"pid":42}"#), "A destructive tool always asks.")
        XCTAssertFalse(ActionApprovalGrant.supportsSimilar(kill, argumentsJSON: #"{"pid":42}"#))
        XCTAssertTrue(ActionApprovalGrant.supportsSimilar(click, argumentsJSON: #"{"pid":42}"#))
        XCTAssertFalse(ActionApprovalGrant.supportsSimilar(click, argumentsJSON: #"{"x":1}"#))
        XCTAssertFalse(ActionApprovalGrant.supportsSimilar(spec("list_windows", risk: .readOnly), argumentsJSON: #"{"pid":42}"#))
    }

    func testExactGrantIgnoresKeyOrderAndWhitespaceOnly() {
        let open = NativeOpenAction.tools[0]
        let grant = ActionApprovalGrant.exact(for: open, argumentsJSON: #"{"name":"Notes"}"#)
        XCTAssertTrue(grant.covers(open, argumentsJSON: #"{ "name" : "Notes" }"#))
        XCTAssertFalse(grant.covers(open, argumentsJSON: #"{"name":"Pages"}"#))
        XCTAssertFalse(grant.covers(NativeOpenAction.tools[1], argumentsJSON: #"{"name":"Notes"}"#))

        let shortcut = NativeOpenAction.tools[2]
        let chord = ActionApprovalGrant.exact(for: shortcut, argumentsJSON: #"{"app":"Notes","keys":["cmd","n"]}"#)
        XCTAssertTrue(chord.covers(shortcut, argumentsJSON: #"{"keys":["cmd","n"],"app":"Notes"}"#))
        XCTAssertFalse(chord.covers(shortcut, argumentsJSON: #"{"keys":["n","cmd"],"app":"Notes"}"#), "Array order is meaningful.")
        XCTAssertEqual(ActionApprovalGrant.canonical("not json"), "not json")
    }

    func testPlanRequestDerivesGrantsFromNativeStepsOnly() throws {
        let open = NativeOpenAction.openApp(name: "Notes")
        let request = ActionPlanApprovalRequest(command: "c", steps: [
            .init(number: 1, text: "a", summary: "Already open", route: .alreadyDone),
            .init(number: 2, text: "b", summary: "Open Notes", route: .native(spec: open.spec, argumentsJSON: try open.argumentsJSON())),
            .init(number: 3, text: "c", summary: "Planned", route: .planned)
        ])
        XCTAssertEqual(request.grants, [.exact(for: open.spec, argumentsJSON: try open.argumentsJSON())])
        XCTAssertEqual(request.steps[1].risk, .mutating)
        XCTAssertNil(request.steps[0].risk)
        XCTAssertNil(request.steps[2].risk)
    }
}
