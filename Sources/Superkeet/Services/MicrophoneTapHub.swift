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

/// Owns the microphone hardware for `MicrophoneTapHub`. The real backend
/// wraps `AVAudioEngine`; tests substitute a fake that emits buffers on demand.
@MainActor
protocol MicrophoneCapturing: AnyObject {
    func start(
        deviceName: String,
        bufferSize: AVAudioFrameCount,
        handler: @escaping MicrophoneTapHub.BufferHandler
    ) throws -> MicrophoneTapHub.CaptureInfo
    func stop()
}

/// One microphone input tap shared by everything that consumes live audio:
/// the recording overlay's level meter, and the partial-transcript recogniser
/// that spots app-launch intents while the user is still speaking. The engine
/// runs while at least one subscriber is attached and stops with the last one,
/// so command mode can hear audio even when no overlay is shown.
@MainActor
final class MicrophoneTapHub: ObservableObject {
    static let shared = MicrophoneTapHub()

    /// Called on the audio tap's thread for every captured buffer.
    typealias BufferHandler = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void

    struct Subscription: Hashable, Sendable {
        fileprivate let id: UUID
    }

    struct CaptureInfo {
        let format: AVAudioFormat
        /// Non-fatal note, for example when the selected microphone is missing
        /// and the default input is used instead.
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

    /// Attaches a handler, starting the microphone if it is not already running.
    /// Throws when capture cannot start; no subscription is retained in that case.
    func subscribe(_ handler: @escaping BufferHandler) throws -> Subscription {
        dispatchPrecondition(condition: .onQueue(.main))
        if !isRunning { try start() }
        let subscription = Subscription(id: UUID())
        fanout.add(subscription.id, handler)
        return subscription
    }

    /// Detaches a handler, stopping the microphone when it was the last one.
    /// Unknown or already-removed subscriptions are ignored.
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

/// Delivers buffers from the audio thread to every subscriber. Membership
/// changes on the main actor; delivery reads a snapshot under the lock so a
/// subscriber can detach while a buffer is in flight.
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

/// `AVAudioEngine` input tap honouring the configured input device.
@MainActor
final class AVAudioEngineMicrophone: MicrophoneCapturing {
    private var engine: AVAudioEngine?

    func start(
        deviceName: String,
        bufferSize: AVAudioFrameCount,
        handler: @escaping MicrophoneTapHub.BufferHandler
    ) throws -> MicrophoneTapHub.CaptureInfo {
        dispatchPrecondition(condition: .onQueue(.main))
        stop()
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

        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MicrophoneTapError.unusableInputFormat
        }

        do {
            try engine.start()
        } catch {
            throw MicrophoneTapError.engineStartFailed(error.localizedDescription)
        }

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format, block: handler)
        self.engine = engine
        return .init(format: format, warning: warning)
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    static let deviceFallbackWarning = "The selected microphone is unavailable; using the default input."
}
