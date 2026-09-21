import XCTest
@testable import Superkeet

final class EngineCancelPolicyTests: XCTestCase {
    func testIdleSettlesImmediately() {
        XCTAssertEqual(EngineCancelPolicy.nextStep(engineState: "idle", polls: 0), .settle)
        XCTAssertEqual(EngineCancelPolicy.nextStep(engineState: "idle", polls: 3), .settle)
    }

    func testTranscribingReplyIsProbedBeforeAnyRestart() {
        // The engine flips its phase before the worker drains, so the cancel ack always says
        // "transcribing". That alone must never trigger a restart.
        XCTAssertEqual(EngineCancelPolicy.nextStep(engineState: "transcribing", polls: 0), .poll(delay: EngineCancelPolicy.pollInterval))
        XCTAssertEqual(
            EngineCancelPolicy.nextStep(engineState: "transcribing", polls: EngineCancelPolicy.maximumPolls - 1),
            .poll(delay: EngineCancelPolicy.pollInterval)
        )
        XCTAssertEqual(EngineCancelPolicy.nextStep(engineState: "transcribing", polls: EngineCancelPolicy.maximumPolls), .settle)
    }

    func testMissingStateFromOlderEnginesProbesAtOnce() {
        XCTAssertEqual(EngineCancelPolicy.nextStep(engineState: nil, polls: 0), .poll(delay: nil))
        XCTAssertEqual(EngineCancelPolicy.nextStep(engineState: nil, polls: 1), .poll(delay: EngineCancelPolicy.pollInterval))
    }

    func testProbeBudgetCoversTheEngineDrain() {
        XCTAssertGreaterThanOrEqual(EngineCancelPolicy.pollInterval * EngineCancelPolicy.maximumPolls, .seconds(1))
        XCTAssertLessThanOrEqual(EngineCancelPolicy.pollInterval * EngineCancelPolicy.maximumPolls, .seconds(3))
    }
}
