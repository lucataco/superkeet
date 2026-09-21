import XCTest
@testable import Superkeet

final class ObservationBindingTests: XCTestCase {
    private let windowState = #"""
    {"snapshot_id":"s1a2b3c4d","pid":18348,"window_id":1,"app_name":"Notes","window_title":"Notes",
     "elements":[{"element_index":184,"element_token":"tok184","role":"AXButton","label":"New Note"},
                 {"element_index":290,"element_token":"tok290","role":"AXMenuItem","label":"New Note"},
                 {"element_index":12,"role":"AXGroup","label":""}]}
    """#

    private let clickSchema = #"""
    {"type":"object","additionalProperties":false,"properties":{
      "element_index":{"type":"integer"},"element_token":{"type":"string"},"snapshot_id":{"type":"string"},
      "pid":{"type":"integer"},"window_id":{"type":"integer"},"session":{"type":"string"},
      "delivery_mode":{"type":"string","enum":["background","foreground"]},"button":{"type":"string"}}}
    """#

    private let windowStateSchema = #"""
    {"type":"object","properties":{"pid":{"type":"integer"},"window_id":{"type":"integer"},"include_screenshot":{"type":"boolean"},
      "query":{"type":"string"},"max_elements":{"type":"integer"}},"required":["pid","window_id"]}
    """#

    private func object(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    func testWindowStateBindsHandlesToElementIndexes() throws {
        var binding = ObservationBinding()
        binding.absorb(resultJSON: windowState, toolName: "get_window_state")
        XCTAssertEqual(binding.pid, 18348)
        XCTAssertEqual(binding.windowID, 1)
        XCTAssertEqual(binding.snapshotID, "s1a2b3c4d")
        XCTAssertEqual(binding.elementTokens, [184: "tok184", 290: "tok290"])
        XCTAssertNil(binding.session)

        let completed = try object(binding.completing(argumentsJSON: #"{"element_index":184}"#, schemaJSON: clickSchema, currentPID: nil))
        XCTAssertEqual(completed["element_index"] as? Int, 184)
        XCTAssertEqual(completed["element_token"] as? String, "tok184")
        XCTAssertEqual(completed["snapshot_id"] as? String, "s1a2b3c4d")
        XCTAssertEqual(completed["pid"] as? Int, 18348)
        XCTAssertEqual(completed["window_id"] as? Int, 1)
        XCTAssertNil(completed["session"])
    }

    func testInventedHandlesAreReplacedOrDropped() throws {
        var binding = ObservationBinding()
        binding.absorb(resultJSON: windowState, toolName: "get_window_state")
        let invented = #"{"element_index":184,"element_token":"***","snapshot_id":"0","session":"abc","pid":0,"window_id":0,"delivery_mode":"background"}"#
        let completed = try object(binding.completing(argumentsJSON: invented, schemaJSON: clickSchema, currentPID: nil))
        XCTAssertEqual(completed["element_token"] as? String, "tok184")
        XCTAssertEqual(completed["snapshot_id"] as? String, "s1a2b3c4d")
        XCTAssertEqual(completed["pid"] as? Int, 18348)
        XCTAssertEqual(completed["window_id"] as? Int, 1)
        XCTAssertNil(completed["session"], "The model never has a real session label; an invented one is dropped.")
        XCTAssertNil(completed["delivery_mode"], "Delivery mode is the server's default, never the model's call.")

        let unknownElement = try object(binding.completing(argumentsJSON: #"{"element_index":999}"#, schemaJSON: clickSchema, currentPID: nil))
        XCTAssertNil(unknownElement["element_token"], "No token for an index that was never observed; the server fails closed on index + snapshot.")
        XCTAssertEqual(unknownElement["snapshot_id"] as? String, "s1a2b3c4d")

        let tokenOnly = try object(binding.completing(argumentsJSON: #"{"element_token":"made-up","snapshot_id":"nope"}"#, schemaJSON: clickSchema, currentPID: nil))
        XCTAssertNil(tokenOnly["element_token"])
        XCTAssertNil(tokenOnly["snapshot_id"])
    }

    func testObservationCallsGetThePidOfTheCurrentAppAndItsFrontWindow() throws {
        var binding = ObservationBinding()
        binding.absorb(resultJSON: #"""
        {"windows":[{"pid":91,"window_id":7,"z_index":5,"is_on_screen":true,"app_name":"Notes"},
                    {"pid":91,"window_id":3,"z_index":2,"is_on_screen":true,"app_name":"Notes"},
                    {"pid":42,"window_id":9,"z_index":8,"is_on_screen":false,"app_name":"Safari"},
                    {"pid":42,"window_id":10,"z_index":1,"is_on_screen":true,"app_name":"Safari"}]}
        """#, toolName: "list_windows")
        XCTAssertEqual(binding.windowsByPID, [91: 7, 42: 10], "On-screen windows win over higher off-screen ones.")
        XCTAssertEqual(binding.frontmost, .init(pid: 91, windowID: 7))

        let notes = try object(binding.completing(argumentsJSON: "{}", schemaJSON: windowStateSchema, currentPID: 91))
        XCTAssertEqual(notes["pid"] as? Int, 91)
        XCTAssertEqual(notes["window_id"] as? Int, 7)

        let noCurrent = try object(binding.completing(argumentsJSON: #"{"include_screenshot":false}"#, schemaJSON: windowStateSchema, currentPID: nil))
        XCTAssertEqual(noCurrent["pid"] as? Int, 91, "Without a current app the frontmost window is the target.")
        XCTAssertEqual(noCurrent["window_id"] as? Int, 7)

        let explicit = try object(binding.completing(argumentsJSON: #"{"pid":42}"#, schemaJSON: windowStateSchema, currentPID: 91))
        XCTAssertEqual(explicit["pid"] as? Int, 42, "A real pid from the model is kept.")
        XCTAssertEqual(explicit["window_id"] as? Int, 10)
    }

    func testCurrentAppWinsOverAStaleSnapshotUnlessAnElementIsNamed() throws {
        var binding = ObservationBinding()
        binding.absorb(resultJSON: windowState, toolName: "get_window_state")
        let fresh = try object(binding.completing(argumentsJSON: "{}", schemaJSON: windowStateSchema, currentPID: 4242))
        XCTAssertEqual(fresh["pid"] as? Int, 4242)
        XCTAssertNil(fresh["window_id"], "No window is known for the new app yet.")
        let element = try object(binding.completing(argumentsJSON: #"{"element_index":290}"#, schemaJSON: clickSchema, currentPID: 4242))
        XCTAssertEqual(element["pid"] as? Int, 18348, "An element belongs to the window it was observed in.")
    }

    func testUnchangedArgumentsAndUnknownShapesPassThrough() {
        var binding = ObservationBinding()
        binding.absorb(resultJSON: "not json", toolName: "get_window_state")
        binding.absorb(resultJSON: #"{"result":"ok"}"#, toolName: "get_window_state")
        XCTAssertEqual(binding, ObservationBinding())
        let untouched = #"{"url":"https://example.com"}"#
        XCTAssertEqual(binding.completing(argumentsJSON: untouched, schemaJSON: #"{"type":"object","properties":{"url":{"type":"string"}}}"#, currentPID: 5), untouched)
        XCTAssertEqual(binding.completing(argumentsJSON: "{}", schemaJSON: clickSchema, currentPID: nil), "{}")
    }

    func testSessionLabelsAreCarriedWhenTheServerIssuedOne() throws {
        var binding = ObservationBinding()
        binding.absorb(resultJSON: #"{"session":"sk-1","elements":[],"snapshot_id":"s00000001","pid":5,"window_id":2}"#, toolName: "get_window_state")
        let completed = try object(binding.completing(argumentsJSON: #"{"element_index":1}"#, schemaJSON: clickSchema, currentPID: nil))
        XCTAssertEqual(completed["session"] as? String, "sk-1")
    }

    func testHiddenHandlesLeaveTheSchemaTheModelSees() throws {
        let projected = try XCTUnwrap(ActionToolSchema.projected(clickSchema, toolName: "cua-driver/click"))
        let properties = try XCTUnwrap(projected["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), ["element_index", "pid", "window_id", "button"])
        XCTAssertEqual(projected["required"] as? [String], [])

        let requiringToken = #"{"type":"object","properties":{"element_token":{"type":"string"},"key":{"type":"string"}},"required":["element_token","key"]}"#
        let pruned = try XCTUnwrap(ActionToolSchema.projected(requiringToken, toolName: "cua-driver/press_key"))
        XCTAssertEqual(pruned["required"] as? [String], ["key"], "A required handle is Superkeet's to supply, not the model's.")
        XCTAssertTrue(ObservationHandles.managesHandles(in: clickSchema))
        XCTAssertFalse(ObservationHandles.managesHandles(in: windowStateSchema))
    }
}
