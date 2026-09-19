import AVFoundation
import XCTest
@testable import Superkeet

@MainActor
final class MicrophoneTapHubTests: XCTestCase {
    final class FakeCapture: MicrophoneCapturing {
        private(set) var startCount = 0
        private(set) var stopCount = 0
        private(set) var deviceNames: [String] = []
        private(set) var bufferSizes: [AVAudioFrameCount] = []
        var failure: Error?
        var warning: String?
        private(set) var handler: MicrophoneTapHub.BufferHandler?

        var isRunning: Bool { handler != nil }

        func start(
            deviceName: String,
            bufferSize: AVAudioFrameCount,
            handler: @escaping MicrophoneTapHub.BufferHandler
        ) throws -> MicrophoneTapHub.CaptureInfo {
            if let failure { throw failure }
            startCount += 1
            deviceNames.append(deviceName)
            bufferSizes.append(bufferSize)
            self.handler = handler
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
            return .init(format: format, warning: warning)
        }

        func stop() {
            stopCount += 1
            handler = nil
        }

        func emit(_ buffer: AVAudioPCMBuffer) {
            handler?(buffer, AVAudioTime(sampleTime: 0, atRate: 48_000))
        }
    }

    private func makeHub(
        capture: FakeCapture,
        authorized: Bool = true,
        device: String = ""
    ) -> MicrophoneTapHub {
        MicrophoneTapHub(capture: capture, authorization: { authorized }, requestedDeviceName: { device })
    }

    private func makeBuffer(sampleValue: Float, frames: Int = 512) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        if let channelData = buffer.floatChannelData {
            for frame in 0..<frames { channelData[0][frame] = sampleValue }
        }
        return buffer
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testFirstSubscriberStartsCaptureAndLastOneStopsIt() throws {
        let capture = FakeCapture()
        let hub = makeHub(capture: capture, device: "USB Microphone")

        let first = try hub.subscribe { _, _ in }
        XCTAssertEqual(capture.startCount, 1)
        XCTAssertEqual(capture.deviceNames, ["USB Microphone"])
        XCTAssertEqual(capture.bufferSizes, [MicrophoneTapHub.bufferSize])
        XCTAssertTrue(hub.isRunning)
        XCTAssertEqual(hub.subscriberCount, 1)
        XCTAssertEqual(hub.inputFormat?.sampleRate, 48_000)

        let second = try hub.subscribe { _, _ in }
        XCTAssertEqual(capture.startCount, 1, "A second subscriber must share the running capture.")
        XCTAssertEqual(hub.subscriberCount, 2)

        hub.unsubscribe(first)
        XCTAssertEqual(capture.stopCount, 0, "Capture keeps running while any subscriber remains.")
        XCTAssertTrue(hub.isRunning)

        hub.unsubscribe(second)
        XCTAssertEqual(capture.stopCount, 1)
        XCTAssertFalse(hub.isRunning)
        XCTAssertEqual(hub.subscriberCount, 0)
        XCTAssertNil(hub.inputFormat)
    }

    func testCaptureRestartsForANewSubscriberAfterStopping() throws {
        let capture = FakeCapture()
        let hub = makeHub(capture: capture)
        let first = try hub.subscribe { _, _ in }
        hub.unsubscribe(first)
        _ = try hub.subscribe { _, _ in }
        XCTAssertEqual(capture.startCount, 2)
        XCTAssertEqual(capture.stopCount, 1)
        XCTAssertTrue(hub.isRunning)
    }

    func testUnsubscribingTwiceOrWithAStaleTokenIsHarmless() throws {
        let capture = FakeCapture()
        let hub = makeHub(capture: capture)
        let first = try hub.subscribe { _, _ in }
        let second = try hub.subscribe { _, _ in }
        hub.unsubscribe(first)
        hub.unsubscribe(first)
        XCTAssertEqual(capture.stopCount, 0)
        XCTAssertEqual(hub.subscriberCount, 1)
        hub.unsubscribe(second)
        hub.unsubscribe(second)
        XCTAssertEqual(capture.stopCount, 1, "Repeated unsubscribes never stop the capture twice.")
    }

    func testDeniedMicrophoneAccessThrowsWithoutTouchingHardware() {
        let capture = FakeCapture()
        let hub = makeHub(capture: capture, authorized: false)
        XCTAssertThrowsError(try hub.subscribe { _, _ in }) { error in
            XCTAssertEqual(error as? MicrophoneTapError, .microphoneAccessDenied)
        }
        XCTAssertEqual(capture.startCount, 0)
        XCTAssertFalse(hub.isRunning)
        XCTAssertEqual(hub.subscriberCount, 0)
    }

    func testCaptureFailureLeavesNoSubscriptionAndAllowsRetry() throws {
        let capture = FakeCapture()
        capture.failure = MicrophoneTapError.engineStartFailed("device busy")
        let hub = makeHub(capture: capture)
        XCTAssertThrowsError(try hub.subscribe { _, _ in }) { error in
            XCTAssertEqual(error as? MicrophoneTapError, .engineStartFailed("device busy"))
        }
        XCTAssertFalse(hub.isRunning)
        XCTAssertEqual(hub.subscriberCount, 0)

        capture.failure = nil
        _ = try hub.subscribe { _, _ in }
        XCTAssertTrue(hub.isRunning)
        XCTAssertEqual(hub.subscriberCount, 1)
    }

    func testDeviceFallbackWarningIsPublishedWhileRunningAndClearedOnStop() throws {
        let capture = FakeCapture()
        capture.warning = AVAudioEngineMicrophone.deviceFallbackWarning
        let hub = makeHub(capture: capture, device: "Missing Mic")
        let subscription = try hub.subscribe { _, _ in }
        XCTAssertEqual(hub.warning, AVAudioEngineMicrophone.deviceFallbackWarning)
        hub.unsubscribe(subscription)
        XCTAssertNil(hub.warning)
    }

    func testBuffersReachEverySubscriberAndStopAfterDetach() throws {
        let capture = FakeCapture()
        let hub = makeHub(capture: capture)
        let received = OSAllocatedUnfairLockBox<[String: Int]>([:])

        let first = try hub.subscribe { buffer, _ in received.mutate { $0["first", default: 0] += Int(buffer.frameLength) } }
        let second = try hub.subscribe { buffer, _ in received.mutate { $0["second", default: 0] += Int(buffer.frameLength) } }

        capture.emit(try makeBuffer(sampleValue: 0.1, frames: 256))
        XCTAssertEqual(received.value, ["first": 256, "second": 256])

        hub.unsubscribe(first)
        capture.emit(try makeBuffer(sampleValue: 0.1, frames: 128))
        XCTAssertEqual(received.value, ["first": 256, "second": 384], "A detached subscriber receives nothing further.")
        hub.unsubscribe(second)
    }

    func testFanoutDeliveryToleratesRemovalDuringDispatch() throws {
        let fanout = BufferFanout()
        let calls = OSAllocatedUnfairLockBox(0)
        let ids = (0..<3).map { _ in UUID() }
        for id in ids {
            fanout.add(id) { _, _ in
                calls.mutate { $0 += 1 }
                _ = fanout.remove(ids[0])
            }
        }
        fanout.dispatch(try makeBuffer(sampleValue: 0), AVAudioTime(sampleTime: 0, atRate: 48_000))
        XCTAssertEqual(calls.value, 3, "Delivery uses a snapshot, so removing a handler mid-dispatch is safe.")
        XCTAssertEqual(fanout.count, 2)
    }

    func testLevelMonitorSubscribesAndPublishesLevels() async throws {
        let capture = FakeCapture()
        let hub = makeHub(capture: capture)
        let monitor = AudioLevelMonitor(hub: hub)

        monitor.startMonitoring()
        XCTAssertTrue(monitor.isMonitoring)
        XCTAssertNil(monitor.errorMessage)
        XCTAssertEqual(hub.subscriberCount, 1)

        capture.emit(try makeBuffer(sampleValue: 1.0))
        await waitUntil { monitor.levels.contains { $0 > 0 } }
        XCTAssertTrue(monitor.levels.contains { $0 > 0 })
        XCTAssertEqual(monitor.levels.count, AudioLevelMonitor.bandCount)

        monitor.stopMonitoring()
        XCTAssertFalse(monitor.isMonitoring)
        XCTAssertTrue(monitor.levels.allSatisfy { $0 == 0 })
        XCTAssertEqual(hub.subscriberCount, 0)
        XCTAssertEqual(capture.stopCount, 1)
    }

    func testLevelMonitorStartIsIdempotentAndSharesCaptureWithOtherSubscribers() throws {
        let capture = FakeCapture()
        let hub = makeHub(capture: capture)
        let monitor = AudioLevelMonitor(hub: hub)
        let other = try hub.subscribe { _, _ in }

        monitor.startMonitoring()
        monitor.startMonitoring()
        XCTAssertEqual(hub.subscriberCount, 2)
        XCTAssertEqual(capture.startCount, 1)

        monitor.stopMonitoring()
        XCTAssertEqual(hub.subscriberCount, 1)
        XCTAssertTrue(hub.isRunning, "Stopping the meter must not silence the other subscriber.")
        XCTAssertEqual(capture.stopCount, 0)
        hub.unsubscribe(other)
        XCTAssertEqual(capture.stopCount, 1)
    }

    func testLevelMonitorSurfacesCaptureErrorsAndWarnings() throws {
        let denied = makeHub(capture: FakeCapture(), authorized: false)
        let deniedMonitor = AudioLevelMonitor(hub: denied)
        deniedMonitor.startMonitoring()
        XCTAssertFalse(deniedMonitor.isMonitoring)
        XCTAssertEqual(deniedMonitor.errorMessage, MicrophoneTapError.microphoneAccessDenied.localizedDescription)

        let capture = FakeCapture()
        capture.warning = AVAudioEngineMicrophone.deviceFallbackWarning
        let monitor = AudioLevelMonitor(hub: makeHub(capture: capture, device: "Missing Mic"))
        monitor.startMonitoring()
        XCTAssertTrue(monitor.isMonitoring, "A device fallback is a warning, not a failure.")
        XCTAssertEqual(monitor.errorMessage, AVAudioEngineMicrophone.deviceFallbackWarning)
        monitor.stopMonitoring()
        XCTAssertNil(monitor.errorMessage)
    }
}

final class OSAllocatedUnfairLockBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&stored)
    }
}
