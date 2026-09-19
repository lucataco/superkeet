import AVFoundation
import Foundation
import os

private let microphoneLog = Logger(subsystem: "com.superkeet.app", category: "MicrophoneTapHub")

enum MicrophoneTapError: LocalizedError, Equatable {
    case microphoneAccessDenied
    case unusableInputFormat
    case engineStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphoneAccessDenied:
            return "Microphone access is required to capture audio."
        case .unusableInputFormat:
            return "Audio engine reported no usable input format."
        case .engineStartFailed(let detail):
            return detail
        }
    }
}

@MainActor
protocol MicrophoneCapturing: AnyObject {
    func start(
        deviceName: String,
        bufferSize: AVAudioFrameCount,
        handler: @escaping MicrophoneTapHub.BufferHandler
    ) throws -> MicrophoneTapHub.CaptureInfo
    func stop()
    /// Set up everything short of opening the device so the first `start` is fast. Optional.
    func prewarm(deviceName: String)
}

extension MicrophoneCapturing {
    func prewarm(deviceName: String) {}
}

@MainActor
final class MicrophoneTapHub: ObservableObject {
    static let shared = MicrophoneTapHub()

    typealias BufferHandler = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void

    struct Subscription: Hashable, Sendable {
        fileprivate let id: UUID
    }

    struct CaptureInfo {
        let format: AVAudioFormat
        let warning: String?
    }

    static let bufferSize: AVAudioFrameCount = 1_024

    @Published private(set) var isRunning = false
    @Published private(set) var warning: String?
    private(set) var inputFormat: AVAudioFormat?

    private let capture: any MicrophoneCapturing
    private let authorization: @MainActor () -> Bool
    private let requestedDeviceName: @MainActor () -> String
    private let fanout = BufferFanout()

    init(
        capture: (any MicrophoneCapturing)? = nil,
        authorization: (@MainActor () -> Bool)? = nil,
        requestedDeviceName: (@MainActor () -> String)? = nil
    ) {
        self.capture = capture ?? AVAudioEngineMicrophone()
        self.authorization = authorization ?? { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
        self.requestedDeviceName = requestedDeviceName ?? { AppSettings.shared.audioInputDevice }
    }

    var subscriberCount: Int { fanout.count }

    /// Builds the audio graph ahead of time (no device IO, so no mic indicator) so the first
    /// recording's level meter appears without a visible stall.
    func prewarm() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isRunning, authorization() else { return }
        capture.prewarm(deviceName: requestedDeviceName())
    }

    func subscribe(_ handler: @escaping BufferHandler) throws -> Subscription {
        dispatchPrecondition(condition: .onQueue(.main))
        if !isRunning { try start() }
        let subscription = Subscription(id: UUID())
        fanout.add(subscription.id, handler)
        return subscription
    }

    func unsubscribe(_ subscription: Subscription) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard fanout.remove(subscription.id) else { return }
        if fanout.isEmpty { stop() }
    }

    private func start() throws {
        guard authorization() else { throw MicrophoneTapError.microphoneAccessDenied }
        let fanout = self.fanout
        let info: CaptureInfo
        do {
            info = try capture.start(deviceName: requestedDeviceName(), bufferSize: Self.bufferSize) { buffer, time in
                fanout.dispatch(buffer, time)
            }
        } catch {
            microphoneLog.error("Microphone capture failed to start: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        inputFormat = info.format
        warning = info.warning
        isRunning = true
    }

    private func stop() {
        capture.stop()
        isRunning = false
        inputFormat = nil
        warning = nil
    }
}

final class BufferFanout: Sendable {
    private let handlers = OSAllocatedUnfairLock<[UUID: MicrophoneTapHub.BufferHandler]>(initialState: [:])

    var count: Int { handlers.withLock { $0.count } }
    var isEmpty: Bool { handlers.withLock { $0.isEmpty } }

    func add(_ id: UUID, _ handler: @escaping MicrophoneTapHub.BufferHandler) {
        handlers.withLock { $0[id] = handler }
    }

    func remove(_ id: UUID) -> Bool {
        handlers.withLock { $0.removeValue(forKey: id) != nil }
    }

    func dispatch(_ buffer: AVAudioPCMBuffer, _ time: AVAudioTime) {
        let snapshot = handlers.withLock { Array($0.values) }
        for handler in snapshot { handler(buffer, time) }
    }
}

/// Wraps one long-lived `AVAudioEngine`. Building the engine and touching `inputNode` sets up the
/// HAL audio unit, which is the slow part of opening a microphone; keeping the engine between
/// takes means each recording only pays for the device start itself.
@MainActor
final class AVAudioEngineMicrophone: MicrophoneCapturing {
    private var engine: AVAudioEngine?
    private var engineDeviceName: String?
    private var engineWarning: String?
    private var isTapInstalled = false

    func prewarm(deviceName: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard engine == nil || engineDeviceName != deviceName else { return }
        _ = prepareEngine(deviceName: deviceName)
    }

    func start(
        deviceName: String,
        bufferSize: AVAudioFrameCount,
        handler: @escaping MicrophoneTapHub.BufferHandler
    ) throws -> MicrophoneTapHub.CaptureInfo {
        dispatchPrecondition(condition: .onQueue(.main))
        removeTap()

        var (engine, warning) = reusableEngine(for: deviceName) ?? prepareEngine(deviceName: deviceName)
        var format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            discardEngine()
            throw MicrophoneTapError.unusableInputFormat
        }

        do {
            try engine.start()
        } catch {
            // A reused engine can go stale if the hardware configuration changed underneath it.
            // Rebuild once before giving up.
            microphoneLog.info("Reused audio engine failed to start; rebuilding: \(error.localizedDescription, privacy: .public)")
            discardEngine()
            (engine, warning) = prepareEngine(deviceName: deviceName)
            format = engine.inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                discardEngine()
                throw MicrophoneTapError.unusableInputFormat
            }
            do {
                try engine.start()
            } catch {
                discardEngine()
                throw MicrophoneTapError.engineStartFailed(error.localizedDescription)
            }
        }

        engine.inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format, block: handler)
        isTapInstalled = true
        return .init(format: format, warning: warning)
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        removeTap()
        guard let engine else { return }
        engine.stop()
        // Keep the graph allocated so the next take starts quickly; the device itself is closed.
        engine.prepare()
    }

    private func removeTap() {
        guard isTapInstalled else { return }
        engine?.inputNode.removeTap(onBus: 0)
        isTapInstalled = false
    }

    private func reusableEngine(for deviceName: String) -> (AVAudioEngine, String?)? {
        guard let engine, engineDeviceName == deviceName else {
            discardEngine()
            return nil
        }
        return (engine, engineWarning)
    }

    private func prepareEngine(deviceName: String) -> (AVAudioEngine, String?) {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        var warning: String?

        if !deviceName.isEmpty {
            if let deviceID = AudioInputDeviceResolver.deviceID(forName: deviceName) {
                do {
                    try inputNode.auAudioUnit.setDeviceID(deviceID)
                } catch {
                    microphoneLog.error("Failed to set input device \(deviceName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    warning = Self.deviceFallbackWarning
                }
            } else {
                warning = Self.deviceFallbackWarning
            }
        }

        engine.prepare()
        self.engine = engine
        self.engineDeviceName = deviceName
        self.engineWarning = warning
        return (engine, warning)
    }

    private func discardEngine() {
        removeTap()
        engine?.stop()
        engine = nil
        engineDeviceName = nil
        engineWarning = nil
    }

    static let deviceFallbackWarning = "The selected microphone is unavailable; using the default input."
}
