import XCTest
import AVFoundation
@testable import Superkeet

final class SetupVerificationTests: XCTestCase {

    func testSetupSmokeTestRequiresDaemonStart() {
        let report = makeReport(issues: [])

        XCTAssertFalse(report.passesSetupSmokeTest(daemonStarted: false))
        XCTAssertTrue(report.passesSetupSmokeTest(daemonStarted: true))
    }

    func testSetupSmokeTestFailsWhenRecordingIsBlocked() {
        let report = makeReport(issues: [.microphone])

        XCTAssertFalse(report.passesSetupSmokeTest(daemonStarted: true))
    }

    func testSetupSmokeTestFailsWhenAutoPasteNeedsAccessibility() {
        let report = makeReport(issues: [.accessibility])

        XCTAssertTrue(report.passesSetupSmokeTest(daemonStarted: true))
        XCTAssertFalse(report.passesSetupSmokeTest(daemonStarted: true, autoPasteEnabled: true))
    }

    func testSetupSmokeTestFailsWhenModelMissing() {
        let report = makeReport(issues: [.model])

        XCTAssertTrue(report.needsModelDownload)
        XCTAssertFalse(report.isReadyForBasicRecording)
        XCTAssertFalse(report.passesSetupSmokeTest(daemonStarted: true))
    }

    func testMissingModelIsNotADaemonBlockingIssue() {
        // A missing model is a recoverable first-run download, not a broken
        // install — it must not trip the "reinstall the app" error path.
        let report = makeReport(issues: [.model])

        XCTAssertFalse(report.hasDaemonBlockingIssue)
        XCTAssertTrue(report.isReadyForDaemon)
    }

    private func makeReport(issues: [AppReadinessIssue]) -> AppReadinessReport {
        AppReadinessReport(
            issues: issues,
            diagnostics: AppDiagnostics(
                microphoneStatus: .authorized,
                availableInputDeviceNames: ["Built-in Microphone"],
                engineBinaryExists: true,
                modelInstalled: true,
                runtimeDirectory: URL(fileURLWithPath: "/tmp/superkeet-tests"),
                runtimeDirectoryWritable: true,
                configuredInputDeviceFound: true
            )
        )
    }
}
