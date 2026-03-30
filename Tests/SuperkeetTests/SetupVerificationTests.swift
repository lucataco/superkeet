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

    private func makeReport(issues: [AppReadinessIssue]) -> AppReadinessReport {
        AppReadinessReport(
            issues: issues,
            diagnostics: AppDiagnostics(
                microphoneStatus: .authorized,
                availableInputDeviceNames: ["Built-in Microphone"],
                engineBinaryExists: true,
                runtimeDirectory: URL(fileURLWithPath: "/tmp/superkeet-tests"),
                runtimeDirectoryWritable: true,
                configuredInputDeviceFound: true
            )
        )
    }
}
