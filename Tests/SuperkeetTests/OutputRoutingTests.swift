import XCTest
@testable import Superkeet

final class OutputRoutingTests: XCTestCase {

    func testEveryTakeIsCopiedToTheClipboard() {
        // There is no configuration that strands text inside the app.
        for keep in [false, true] {
            for paste in [false, true] {
                for history in [false, true] {
                    let decision = OutputRouting.decision(
                        keepOnClipboardAfterPaste: keep, autoPasteEnabled: paste, saveHistoryEnabled: history
                    )
                    XCTAssertTrue(decision.shouldCopyToClipboard, "keep=\(keep) paste=\(paste) history=\(history)")
                    XCTAssertEqual(decision.shouldAutoPaste, paste)
                    XCTAssertEqual(decision.shouldSaveHistory, history)
                }
            }
        }
    }

    func testClipboardIsOnlyRestoredWhenAutoPasteIsOnAndKeepIsOff() {
        XCTAssertFalse(
            OutputRouting.decision(keepOnClipboardAfterPaste: false, autoPasteEnabled: true, saveHistoryEnabled: false)
                .shouldKeepClipboardAfterPaste
        )
        XCTAssertTrue(
            OutputRouting.decision(keepOnClipboardAfterPaste: true, autoPasteEnabled: true, saveHistoryEnabled: false)
                .shouldKeepClipboardAfterPaste
        )
        // Without auto-paste there is no paste to restore after; the transcript simply stays copied.
        XCTAssertTrue(
            OutputRouting.decision(keepOnClipboardAfterPaste: false, autoPasteEnabled: false, saveHistoryEnabled: false)
                .shouldKeepClipboardAfterPaste
        )
    }
}
