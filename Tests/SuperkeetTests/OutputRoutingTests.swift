import XCTest
@testable import Superkeet

final class OutputRoutingTests: XCTestCase {
    func testAutoPasteAlwaysCopiesFirst() {
        let decision = OutputRouting.decision(
            clipboardCopyEnabled: false,
            autoPasteEnabled: true,
            saveHistoryEnabled: true
        )

        XCTAssertTrue(decision.shouldCopyToClipboard)
        XCTAssertTrue(decision.shouldAutoPaste)
        XCTAssertTrue(decision.shouldSaveHistory)
    }

    func testClipboardOnlyFlowStaysSimple() {
        let decision = OutputRouting.decision(
            clipboardCopyEnabled: true,
            autoPasteEnabled: false,
            saveHistoryEnabled: false
        )

        XCTAssertTrue(decision.shouldCopyToClipboard)
        XCTAssertFalse(decision.shouldAutoPaste)
        XCTAssertFalse(decision.shouldSaveHistory)
    }

    func testNoOutputDestinationsMeansNoClipboardOrPaste() {
        let decision = OutputRouting.decision(
            clipboardCopyEnabled: false,
            autoPasteEnabled: false,
            saveHistoryEnabled: true
        )

        XCTAssertFalse(decision.shouldCopyToClipboard)
        XCTAssertFalse(decision.shouldAutoPaste)
        XCTAssertTrue(decision.shouldSaveHistory)
    }
}
