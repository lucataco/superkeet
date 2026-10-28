import XCTest
@testable import Superkeet

final class SetupSummaryTests: XCTestCase {

    func testBlockingIssueHidesAccessibilityUnlessAutoPasteIsOn() {
        XCTAssertEqual(makeSummary([.microphone]), .needsAttention([.microphone]))
        XCTAssertEqual(makeSummary([.microphone, .accessibility]), .needsAttention([.microphone]))
        XCTAssertEqual(
            makeSummary([.microphone, .accessibility], autoPasteEnabled: true),
            .needsAttention([.microphone, .accessibility])
        )
    }

    func testMissingModelNeedsAttentionWhenNotDownloading() {
        XCTAssertEqual(makeSummary([.model], model: .notInstalled), .needsAttention([.model]))
        XCTAssertEqual(makeSummary([.model], model: .failed("Network lost")), .needsAttention([.model]))
    }

    func testDownloadingModelShowsPercent() {
        XCTAssertEqual(makeSummary([.model], model: downloading(0.42)), .downloadingModel(percent: 42))
        XCTAssertEqual(makeSummary([.model], model: downloading(0)), .downloadingModel(percent: 0))
    }

    func testCheckingAndVerifyingModelShowNoPercent() {
        XCTAssertEqual(makeSummary([.model], model: .checking), .downloadingModel(percent: nil))
        XCTAssertEqual(makeSummary([.model], model: .verifying), .downloadingModel(percent: nil))
    }

    func testModelItemIsHiddenWhileDownloadingBehindOtherBlockers() {
        XCTAssertEqual(makeSummary([.model, .microphone], model: downloading(0.42)), .needsAttention([.microphone]))
    }

    func testDownloadingWinsOverAccessibility() {
        XCTAssertEqual(
            makeSummary([.model, .accessibility], model: downloading(0.42), autoPasteEnabled: true),
            .downloadingModel(percent: 42)
        )
    }

    func testAccessibilityAloneNeedsAccessibility() {
        XCTAssertEqual(makeSummary([.accessibility]), .needsAccessibility(autoPaste: false))
        XCTAssertEqual(makeSummary([.accessibility], autoPasteEnabled: true), .needsAccessibility(autoPaste: true))
    }

    func testNoIssuesIsReady() {
        XCTAssertEqual(makeSummary([]), .ready)
        XCTAssertEqual(makeSummary([], autoPasteEnabled: true), .ready)
    }

    func testMessages() {
        let shortcut = "⌥Space"

        XCTAssertEqual(
            SetupSummary.ready.message(toggleShortcut: shortcut),
            "Press ⌥Space to start dictating, then press it again to stop."
        )
        XCTAssertEqual(
            SetupSummary.downloadingModel(percent: 42).message(toggleShortcut: shortcut),
            "The speech model is downloading (42%). Dictation works as soon as it finishes."
        )
        XCTAssertEqual(
            SetupSummary.downloadingModel(percent: nil).message(toggleShortcut: shortcut),
            "The speech model is downloading. Dictation works as soon as it finishes."
        )
        XCTAssertEqual(
            SetupSummary.needsAccessibility(autoPaste: false).message(toggleShortcut: shortcut),
            "Turn on Accessibility so ⌥Space works in every app. Until then, click the menu bar icon and choose Start Recording."
        )
        XCTAssertEqual(
            SetupSummary.needsAccessibility(autoPaste: true).message(toggleShortcut: shortcut),
            "Turn on Accessibility so ⌥Space and automatic paste work in every app. Until then, transcripts are copied to the clipboard."
        )
        XCTAssertEqual(
            SetupSummary.needsAttention([.microphone]).message(toggleShortcut: shortcut),
            "Fix the items below to start dictating. You can also fix them later in Settings."
        )
    }

    func testTitles() {
        XCTAssertEqual(SetupSummary.ready.title, "You're all set")
        XCTAssertEqual(SetupSummary.downloadingModel(percent: 42).title, "Almost ready")
        XCTAssertEqual(SetupSummary.needsAccessibility(autoPaste: false).title, "Almost ready")
        XCTAssertEqual(SetupSummary.needsAccessibility(autoPaste: true).title, "Almost ready")
        XCTAssertEqual(SetupSummary.needsAttention([.microphone]).title, "Setup needs attention")
    }

    func testCompletionButtonTitles() {
        XCTAssertEqual(SetupSummary.ready.completionButtonTitle, "Start Using Superkeet")
        XCTAssertEqual(SetupSummary.downloadingModel(percent: 42).completionButtonTitle, "Start Using Superkeet")
        XCTAssertEqual(SetupSummary.needsAccessibility(autoPaste: true).completionButtonTitle, "Start Using Superkeet")
        XCTAssertEqual(SetupSummary.needsAttention([.microphone]).completionButtonTitle, "Continue to Superkeet")
    }

    private func makeSummary(
        _ issues: [AppReadinessIssue],
        model: ModelProvisionState = .installed,
        autoPasteEnabled: Bool = false
    ) -> SetupSummary {
        SetupSummary.make(
            report: AppReadinessReport(issues: issues, diagnostics: Self.diagnostics),
            model: model,
            autoPasteEnabled: autoPasteEnabled
        )
    }

    private func downloading(_ fraction: Double) -> ModelProvisionState {
        .downloading(ModelDownloadProgress(overallFraction: fraction))
    }

    private static let diagnostics = AppDiagnostics(
        microphoneStatus: .authorized,
        availableInputDeviceNames: ["Built-in Microphone"],
        engineBinaryExists: true,
        modelInstalled: true,
        runtimeDirectory: URL(fileURLWithPath: "/tmp/superkeet-tests"),
        runtimeDirectoryWritable: true,
        configuredInputDeviceFound: true,
        hostIsAppleSilicon: true
    )
}
