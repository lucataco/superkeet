import XCTest
@testable import Superkeet

final class OutputRoutingTests: XCTestCase {

    func testOutputRoutingDecisionMatrix() {
        struct Case {
            let name: String
            let clipboard: Bool
            let autoPaste: Bool
            let history: Bool
            let expected: OutputRoutingDecision
        }

        let cases = [
            Case(
                name: "all disabled",
                clipboard: false,
                autoPaste: false,
                history: false,
                expected: OutputRoutingDecision(
                    shouldCopyToClipboard: false,
                    shouldAutoPaste: false,
                    shouldSaveHistory: false,
                    shouldKeepClipboardAfterPaste: false
                )
            ),
            Case(
                name: "history only",
                clipboard: false,
                autoPaste: false,
                history: true,
                expected: OutputRoutingDecision(
                    shouldCopyToClipboard: false,
                    shouldAutoPaste: false,
                    shouldSaveHistory: true,
                    shouldKeepClipboardAfterPaste: false
                )
            ),
            Case(
                name: "clipboard only",
                clipboard: true,
                autoPaste: false,
                history: false,
                expected: OutputRoutingDecision(
                    shouldCopyToClipboard: true,
                    shouldAutoPaste: false,
                    shouldSaveHistory: false,
                    shouldKeepClipboardAfterPaste: true
                )
            ),
            Case(
                name: "clipboard and history",
                clipboard: true,
                autoPaste: false,
                history: true,
                expected: OutputRoutingDecision(
                    shouldCopyToClipboard: true,
                    shouldAutoPaste: false,
                    shouldSaveHistory: true,
                    shouldKeepClipboardAfterPaste: true
                )
            ),
            Case(
                name: "auto-paste only",
                clipboard: false,
                autoPaste: true,
                history: false,
                expected: OutputRoutingDecision(
                    shouldCopyToClipboard: true,
                    shouldAutoPaste: true,
                    shouldSaveHistory: false,
                    shouldKeepClipboardAfterPaste: false
                )
            ),
            Case(
                name: "auto-paste and history",
                clipboard: false,
                autoPaste: true,
                history: true,
                expected: OutputRoutingDecision(
                    shouldCopyToClipboard: true,
                    shouldAutoPaste: true,
                    shouldSaveHistory: true,
                    shouldKeepClipboardAfterPaste: false
                )
            ),
            Case(
                name: "auto-paste with clipboard",
                clipboard: true,
                autoPaste: true,
                history: false,
                expected: OutputRoutingDecision(
                    shouldCopyToClipboard: true,
                    shouldAutoPaste: true,
                    shouldSaveHistory: false,
                    shouldKeepClipboardAfterPaste: true
                )
            ),
            Case(
                name: "all enabled",
                clipboard: true,
                autoPaste: true,
                history: true,
                expected: OutputRoutingDecision(
                    shouldCopyToClipboard: true,
                    shouldAutoPaste: true,
                    shouldSaveHistory: true,
                    shouldKeepClipboardAfterPaste: true
                )
            )
        ]

        for testCase in cases {
            let decision = OutputRouting.decision(
                clipboardCopyEnabled: testCase.clipboard,
                autoPasteEnabled: testCase.autoPaste,
                saveHistoryEnabled: testCase.history
            )

            XCTAssertEqual(decision, testCase.expected, testCase.name)
        }
    }
}
