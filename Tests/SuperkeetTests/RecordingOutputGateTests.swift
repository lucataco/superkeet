import XCTest
@testable import Superkeet

final class RecordingOutputGateTests: XCTestCase {
    func testClosedByDefault() {
        XCTAssertFalse(RecordingOutputGate().isOpen)
    }

    func testOpenAllowsDelivery() {
        var gate = RecordingOutputGate()
        gate.open()
        XCTAssertTrue(gate.isOpen)
    }

    func testCancelBlocksDelivery() {
        var gate = RecordingOutputGate()
        gate.open()
        gate.close()
        XCTAssertFalse(gate.isOpen)
    }

    func testStopLeavesGateOpen() {
        var gate = RecordingOutputGate()
        gate.open()
        XCTAssertTrue(gate.isOpen)
    }

    func testReopenAfterCancelAllowsNextSession() {
        var gate = RecordingOutputGate()
        gate.open()
        gate.close()
        gate.open()
        XCTAssertTrue(gate.isOpen)
    }
}
