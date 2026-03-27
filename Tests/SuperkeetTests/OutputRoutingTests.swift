import XCTest
@testable import Superkeet

final class OutputRoutingTests: XCTestCase {

    // MARK: - Existing tests

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

    // MARK: - Remaining combinations

    func testAllDisabled() {
        let decision = OutputRouting.decision(
            clipboardCopyEnabled: false,
            autoPasteEnabled: false,
            saveHistoryEnabled: false
        )

        XCTAssertFalse(decision.shouldCopyToClipboard)
        XCTAssertFalse(decision.shouldAutoPaste)
        XCTAssertFalse(decision.shouldSaveHistory)
    }

    func testAllEnabled() {
        let decision = OutputRouting.decision(
            clipboardCopyEnabled: true,
            autoPasteEnabled: true,
            saveHistoryEnabled: true
        )

        XCTAssertTrue(decision.shouldCopyToClipboard)
        XCTAssertTrue(decision.shouldAutoPaste)
        XCTAssertTrue(decision.shouldSaveHistory)
    }

    func testAutoPasteWithClipboardNoHistory() {
        let decision = OutputRouting.decision(
            clipboardCopyEnabled: true,
            autoPasteEnabled: true,
            saveHistoryEnabled: false
        )

        XCTAssertTrue(decision.shouldCopyToClipboard)
        XCTAssertTrue(decision.shouldAutoPaste)
        XCTAssertFalse(decision.shouldSaveHistory)
    }

    func testClipboardWithHistory() {
        let decision = OutputRouting.decision(
            clipboardCopyEnabled: true,
            autoPasteEnabled: false,
            saveHistoryEnabled: true
        )

        XCTAssertTrue(decision.shouldCopyToClipboard)
        XCTAssertFalse(decision.shouldAutoPaste)
        XCTAssertTrue(decision.shouldSaveHistory)
    }

    func testAutoPasteForcesClipboardEvenWithoutHistory() {
        let decision = OutputRouting.decision(
            clipboardCopyEnabled: false,
            autoPasteEnabled: true,
            saveHistoryEnabled: false
        )

        XCTAssertTrue(decision.shouldCopyToClipboard, "autoPaste must force clipboard copy")
        XCTAssertTrue(decision.shouldAutoPaste)
        XCTAssertFalse(decision.shouldSaveHistory)
    }

    // MARK: - Invariant: autoPaste always implies clipboard

    func testAutoPasteInvariant() {
        // For all combinations where autoPaste is true, shouldCopyToClipboard must also be true
        for clipboard in [false, true] {
            for history in [false, true] {
                let decision = OutputRouting.decision(
                    clipboardCopyEnabled: clipboard,
                    autoPasteEnabled: true,
                    saveHistoryEnabled: history
                )
                XCTAssertTrue(
                    decision.shouldCopyToClipboard,
                    "autoPaste=true must force clipboard (clipboard=\(clipboard), history=\(history))"
                )
            }
        }
    }
}
