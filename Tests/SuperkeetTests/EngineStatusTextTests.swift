import XCTest
@testable import Superkeet

final class EngineStatusTextTests: XCTestCase {
    func testIdleShutdownReadsAsReady() {
        XCTAssertEqual(EngineStatusText.whileStopped(daemonState: .stopped, model: .installed, runtimeIssue: nil),
                       "Ready — the engine starts when you record")
    }

    func testDownloadShowsProgressEvenWhileTheEngineWaits() {
        var progress = ModelDownloadProgress()
        progress.overallFraction = 0.416
        XCTAssertEqual(EngineStatusText.whileStopped(daemonState: .starting, model: .downloading(progress), runtimeIssue: nil),
                       "Downloading speech model… 42%")
        XCTAssertEqual(EngineStatusText.whileStopped(daemonState: .starting, model: .verifying, runtimeIssue: nil), "Verifying speech model…")
    }

    func testStartingAndStoppingAreNamed() {
        XCTAssertEqual(EngineStatusText.whileStopped(daemonState: .starting, model: .installed, runtimeIssue: nil), "Starting speech engine…")
        XCTAssertEqual(EngineStatusText.whileStopped(daemonState: .stopping, model: .installed, runtimeIssue: nil), "Stopping speech engine…")
    }

    func testRealProblemsPointToSettings() {
        XCTAssertEqual(EngineStatusText.whileStopped(daemonState: .stopped, model: .installed, runtimeIssue: "crashed"),
                       "Speech engine stopped — see Settings")
        XCTAssertEqual(EngineStatusText.whileStopped(daemonState: .stopped, model: .failed("offline"), runtimeIssue: nil),
                       "Speech model download failed — see Settings")
        XCTAssertEqual(EngineStatusText.whileStopped(daemonState: .stopped, model: .notInstalled, runtimeIssue: nil),
                       "Speech model not installed — run Setup")
    }
}
