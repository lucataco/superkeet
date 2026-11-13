import XCTest
@testable import Superkeet

/// Runs takes against the real speech engine. No speech is needed: every take here is silent.
@MainActor
final class TakeLifecycleLiveTests: XCTestCase {
    private let service = ParakeetService.shared

    private func waitUntil(_ timeout: TimeInterval = 20, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }

    func testTakesStartStopCancelAndRefuseASecondTakeOnTheRealEngine() async throws {
        guard ProcessInfo.processInfo.environment["SUPERKEET_DAEMON_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set SUPERKEET_DAEMON_LIVE_TESTS=1 to run against the real speech engine.")
        }
        try await service.startDaemon()
        defer { Task { await service.stopDaemonAndWait() } }

        // A take that runs to the end, and a second request while it is transcribing.
        let dictation = try XCTUnwrap(service.requestTake(kind: .dictation, trigger: .toggle))
        XCTAssertNil(service.requestTake(kind: .command, trigger: .pushToTalk), "Only one take at a time.")
        let started = await service.startRecording(dictation.id)
        XCTAssertEqual(started, .started)
        XCTAssertEqual(service.take?.phase, .recording)
        XCTAssertEqual(service.daemonState, .recording)
        try await Task.sleep(for: .milliseconds(600))
        service.stopRecording()
        XCTAssertEqual(service.take?.phase, .transcribing)
        XCTAssertNil(service.requestTake(kind: .command, trigger: .pushToTalk),
                     "A command cannot be opened over a dictation that is still transcribing.")
        XCTAssertEqual(service.take?.kind, .dictation)
        try await waitUntil { self.service.take == nil }
        XCTAssertNil(service.take)
        XCTAssertEqual(service.daemonState, .idle)

        // Cancelled before the engine was asked.
        let early = try XCTUnwrap(service.requestTake(kind: .command, trigger: .pushToTalk))
        service.cancelRecording()
        XCTAssertNil(service.take)
        let superseded = await service.startRecording(early.id)
        XCTAssertEqual(superseded, .superseded)
        XCTAssertEqual(service.daemonState, .idle)

        // Cancelled while recording.
        let recording = try XCTUnwrap(service.requestTake(kind: .command, trigger: .toggle))
        let recordingStarted = await service.startRecording(recording.id)
        XCTAssertEqual(recordingStarted, .started)
        try await Task.sleep(for: .milliseconds(400))
        service.cancelRecording()
        XCTAssertEqual(service.take?.phase, .cancelling)
        XCTAssertNil(service.requestTake(kind: .dictation, trigger: .toggle))
        try await waitUntil { self.service.take == nil }
        XCTAssertNil(service.take)
        XCTAssertEqual(service.daemonState, .idle)

        // Cancelled while transcribing.
        let late = try XCTUnwrap(service.requestTake(kind: .dictation, trigger: .pushToTalk))
        let lateStarted = await service.startRecording(late.id)
        XCTAssertEqual(lateStarted, .started)
        try await Task.sleep(for: .milliseconds(400))
        service.stopRecording()
        service.cancelRecording()
        try await waitUntil { self.service.take == nil }
        XCTAssertNil(service.take)
        XCTAssertEqual(service.daemonState, .idle)

        // The engine still takes a fresh take after all of that.
        let again = await service.startRecording(kind: .dictation)
        XCTAssertTrue(again)
        service.stopRecording()
        try await waitUntil { self.service.take == nil }
        XCTAssertEqual(service.daemonState, .idle)
    }
}
