import XCTest
@testable import Superkeet

final class WindowProvenanceTests: XCTestCase {
    private let schema = #"{"properties":{"pid":{},"window_id":{}}}"#

    func testOnlyObservedWindowsForTheSameProcessAreTrusted() throws {
        var binding = ObservationBinding()
        binding.absorb(resultJSON: #"{"windows":[{"pid":91,"window_id":7,"z_index":5},{"pid":91,"window_id":8,"z_index":2},{"pid":42,"window_id":9}]}"#, toolName: "list_windows")
        for window in [7, 8] {
            let arguments = "{\"pid\":91,\"window_id\":\(window)}"
            XCTAssertEqual(binding.completing(argumentsJSON: arguments, schemaJSON: schema, currentPID: nil), arguments)
            XCTAssertNil(binding.missingWindowPID(argumentsJSON: arguments, schemaJSON: schema))
        }
        for window in [1, 9] {
            let completed = binding.completing(argumentsJSON: "{\"pid\":91,\"window_id\":\(window)}", schemaJSON: schema, currentPID: nil)
            XCTAssertEqual(completed, #"{"pid":91}"#)
            XCTAssertEqual(binding.missingWindowPID(argumentsJSON: completed, schemaJSON: schema), 91)
        }
    }

    func testScreenshotOnlyStateCountsAsAnObservationAndDoesNotMixProcesses() {
        var binding = ObservationBinding()
        binding.absorb(resultJSON: #"{"pid":91,"window_id":7}"#, toolName: "get_window_state")
        XCTAssertNil(binding.missingWindowPID(argumentsJSON: #"{"pid":91,"window_id":7}"#, schemaJSON: schema))
        binding.absorb(resultJSON: #"{"pid":42,"elements":[]}"#, toolName: "get_window_state")
        XCTAssertEqual(binding.missingWindowPID(argumentsJSON: #"{"pid":42,"window_id":7}"#, schemaJSON: schema), 42)
    }

    func testOnlyWindowObservationsCanIntroduceTrustedWindowIDs() {
        var binding = ObservationBinding()
        binding.absorb(resultJSON: #"{"pid":91,"window_id":7,"elements":[]}"#, toolName: "click")
        binding.absorb(resultJSON: #"{"windows":[{"pid":91,"window_id":7}]}"#, toolName: "launch_app")
        XCTAssertEqual(binding.missingWindowPID(argumentsJSON: #"{"pid":91,"window_id":7}"#, schemaJSON: schema), 91)
    }
}
