import AppKit
import XCTest
@testable import Superkeet

final class PasteServiceTests: XCTestCase {
    private final class Harness {
        let pasteboard = NSPasteboard.withUniqueName()
        var activationSucceeds = true
        var targetReady = true
        var trusted = true
        var pasted: [String] = []
        var issues: [String] = []
        var scheduled: [() -> Void] = []

        lazy var service = PasteService(pasteboard: pasteboard, environment: .init(
            accessibilityTrusted: { [unowned self] in trusted },
            activateTarget: { [unowned self] _ in activationSucceeds },
            targetIsFrontmost: { [unowned self] _ in targetReady },
            sendPaste: { [unowned self] in
                pasted.append(pasteboard.string(forType: .string) ?? "")
                return true
            },
            schedule: { [unowned self] _, action in scheduled.append(action) },
            reportIssue: { [unowned self] in issues.append($0) }
        ))

        func deliver(target: pid_t? = 42) {
            service.deliverText("transcript", decision: OutputRouting.decision(
                clipboardCopyEnabled: false, autoPasteEnabled: true, saveHistoryEnabled: false
            ), targetProcessIdentifier: target)
        }

        func advance() { scheduled.removeFirst()() }
        deinit { pasteboard.releaseGlobally() }
    }

    func testMissingOrUnactivatableTargetNeverPostsPaste() {
        for target in [pid_t(42), nil] {
            let harness = Harness()
            harness.activationSucceeds = false
            harness.deliver(target: target)
            XCTAssertTrue(harness.scheduled.isEmpty)
            XCTAssertTrue(harness.pasted.isEmpty)
            XCTAssertEqual(harness.pasteboard.string(forType: .string), "transcript")
            XCTAssertEqual(harness.issues.count, 1)
        }
    }

    func testTargetExitingOrLosingFocusDuringDelayCancelsPaste() {
        let harness = Harness()
        harness.deliver()
        harness.targetReady = false
        harness.advance()
        XCTAssertTrue(harness.pasted.isEmpty)
        XCTAssertTrue(harness.scheduled.isEmpty)
        XCTAssertEqual(harness.issues.count, 1)
    }

    func testClipboardChangeDuringDelayIsPreservedAndNotPasted() {
        let harness = Harness()
        harness.deliver()
        harness.service.copyToClipboard("unrelated credential")
        harness.advance()
        XCTAssertTrue(harness.pasted.isEmpty)
        XCTAssertTrue(harness.scheduled.isEmpty)
        XCTAssertEqual(harness.pasteboard.string(forType: .string), "unrelated credential")
        XCTAssertEqual(harness.issues.count, 1)
    }

    func testAccessibilityRevocationDuringDelayCancelsPaste() {
        let harness = Harness()
        harness.deliver()
        harness.trusted = false
        harness.advance()
        XCTAssertTrue(harness.pasted.isEmpty)
        XCTAssertEqual(harness.issues.count, 1)
    }

    func testValidDeliveryPastesTranscriptThenRestoresOriginalClipboard() {
        let harness = Harness()
        harness.service.copyToClipboard("original clipboard")
        harness.deliver()
        harness.advance()
        XCTAssertEqual(harness.pasted, ["transcript"])
        harness.advance()
        XCTAssertEqual(harness.pasteboard.string(forType: .string), "original clipboard")
        XCTAssertTrue(harness.issues.isEmpty)
    }

    func testClipboardChangedAfterPasteIsNotRestoredOver() {
        let harness = Harness()
        harness.deliver()
        harness.advance()
        harness.service.copyToClipboard("new clipboard")
        harness.advance()
        XCTAssertEqual(harness.pasteboard.string(forType: .string), "new clipboard")
    }
}
