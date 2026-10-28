import XCTest
@testable import Superkeet

final class EngineStatusTextTests: XCTestCase {
    func testIdleShutdownReadsAsReady() {
        XCTAssertEqual(EngineStatusText.whileStopped(daemonState: .stopped, model: .installed, runtimeIssue: nil), "Ready")
    }

    func testDownloadShowsProgressEvenWhileTheEngineWaits() {
        var progress = ModelDownloadProgress()
        progress.overallFraction = 0.416
        XCTAssertEqual(EngineStatusText.whileStopped(daemonState: .starting, model: .downloading(progress), runtimeIssue: nil),
                       "Downloading speech model… 42%")
        XCTAssertEqual(EngineStatusText.whileStopped(daemonState: .starting, model: .verifying, runtimeIssue: nil), "Verifying speech model…")
    }

    func testStartingAndStoppingAreNamed() {
        XCTAssertEqual(EngineStatusText.whileStopped(daemonState: .starting, model: .installed, runtimeIssue: nil), "Getting ready…")
        XCTAssertEqual(EngineStatusText.whileStopped(daemonState: .stopping, model: .installed, runtimeIssue: nil), "Stopping…")
    }

    func testRealProblemsPointToSettings() {
        XCTAssertEqual(EngineStatusText.whileStopped(daemonState: .stopped, model: .installed, runtimeIssue: "crashed"),
                       "Dictation stopped. Open Settings for details.")
        XCTAssertEqual(EngineStatusText.whileStopped(daemonState: .stopped, model: .failed("offline"), runtimeIssue: nil),
                       "Speech model download failed. Open Settings to retry.")
        XCTAssertEqual(EngineStatusText.whileStopped(daemonState: .stopped, model: .notInstalled, runtimeIssue: nil),
                       "Speech model missing. Open Settings to download it.")
    }
}
