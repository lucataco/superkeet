import AppKit
import XCTest
@testable import Superkeet

final class PasteServiceTests: XCTestCase {
    private final class Deliveries: @unchecked Sendable {
        private(set) var values: [PasteDelivery] = []
        func append(_ delivery: PasteDelivery) { values.append(delivery) }
    }

    private final class Harness {
        let pasteboard = NSPasteboard.withUniqueName()
        var activationSucceeds = true
        var targetReady = true
        var trusted = true
        var pasted: [String] = []
        var issues: [String] = []
        var scheduled: [() -> Void] = []
        var delays: [TimeInterval] = []

        lazy var service = PasteService(pasteboard: pasteboard, environment: .init(
            accessibilityTrusted: { [unowned self] in trusted },
            activateTarget: { [unowned self] _ in activationSucceeds },
            targetIsFrontmost: { [unowned self] _ in targetReady },
            sendPaste: { [unowned self] in
                pasted.append(pasteboard.string(forType: .string) ?? "")
                return true
            },
            schedule: { [unowned self] delay, action in
                delays.append(delay)
                scheduled.append(action)
            },
            reportIssue: { [unowned self] in issues.append($0) }
        ))

        let deliveries = Deliveries()

        func deliver(target: pid_t? = 42, autoPaste: Bool = true) {
            let deliveries = self.deliveries
            service.deliverText("transcript", decision: OutputRouting.decision(
                keepOnClipboardAfterPaste: false, autoPasteEnabled: autoPaste, saveHistoryEnabled: false
            ), targetProcessIdentifier: target, onDelivered: { deliveries.append($0) })
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

    func testDeliveryCallbackReportsCopyImmediately() {
        let harness = Harness()
        harness.deliver(autoPaste: false)
        XCTAssertEqual(harness.deliveries.values, [.copied])
        XCTAssertTrue(harness.scheduled.isEmpty)
    }

    func testDeliveryCallbackReportsPasteOnlyAfterKeystrokeIsSent() {
        let harness = Harness()
        harness.deliver()
        XCTAssertTrue(harness.deliveries.values.isEmpty, "paste is not confirmed until the delayed keystroke fires")
        harness.advance()
        XCTAssertEqual(harness.deliveries.values, [.pasted])
    }

    func testDeliveryCallbackReportsEveryPasteFailureExactlyOnce() {
        let unactivatable = Harness()
        unactivatable.activationSucceeds = false
        unactivatable.deliver()
        XCTAssertEqual(unactivatable.deliveries.values, [.pasteFailed])

        let untrusted = Harness()
        untrusted.trusted = false
        untrusted.deliver()
        XCTAssertEqual(untrusted.deliveries.values, [.pasteFailed])

        let lostFocus = Harness()
        lostFocus.deliver()
        lostFocus.targetReady = false
        lostFocus.advance()
        XCTAssertEqual(lostFocus.deliveries.values, [.pasteFailed])

        let clipboardChanged = Harness()
        clipboardChanged.deliver()
        clipboardChanged.service.copyToClipboard("something else")
        clipboardChanged.advance()
        XCTAssertEqual(clipboardChanged.deliveries.values, [.pasteFailed])
    }

    func testTemporaryTranscriptIsMarkedTransientForClipboardManagers() {
        let harness = Harness()
        harness.deliver()
        let types = harness.pasteboard.types ?? []
        for marker in PasteService.transientTypes {
            XCTAssertTrue(types.contains(marker), "missing \(marker.rawValue)")
        }
    }

    func testCopiedTranscriptIsNotMarkedTransient() {
        let harness = Harness()
        harness.deliver(autoPaste: false)
        let types = harness.pasteboard.types ?? []
        XCTAssertFalse(PasteService.transientTypes.contains { types.contains($0) })
    }

    func testClipboardRestoreWaitsLongEnoughForLazyPasteReaders() {
        let harness = Harness()
        harness.deliver()
        harness.advance()
        XCTAssertEqual(harness.delays.last, PasteService.clipboardRestoreDelay)
        XCTAssertGreaterThanOrEqual(PasteService.clipboardRestoreDelay, 0.5)
    }

    func testRestoreKeepsEveryRestorableTypeOfTheOriginalItem() {
        let harness = Harness()
        let html = NSPasteboard.PasteboardType.html
        harness.pasteboard.clearContents()
        harness.pasteboard.setString("plain", forType: .string)
        harness.pasteboard.setString("<b>rich</b>", forType: html)
        harness.deliver()
        harness.advance()
        harness.advance()
        XCTAssertEqual(harness.pasteboard.string(forType: .string), "plain")
        XCTAssertEqual(harness.pasteboard.string(forType: html), "<b>rich</b>")
    }
}
