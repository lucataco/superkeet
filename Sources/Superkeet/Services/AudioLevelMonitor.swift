import Foundation
import AVFoundation
import CoreAudio
import os.log

private let audioLevelLog = Logger(subsystem: "com.superkeet.app", category: "AudioLevelMonitor")

/// Monitors microphone audio levels for the equalizer visualization.
/// Uses AVAudioEngine with an input tap, separate from Parakeet's mic capture.
final class AudioLevelMonitor: ObservableObject {
    static let shared = AudioLevelMonitor()

    /// Current audio levels for equalizer bars (0.0 to 1.0), throttled to 15 Hz.
    @Published private(set) var levels: [Float] = Array(repeating: 0, count: 8)

    /// Whether monitoring is active
    @Published private(set) var isMonitoring: Bool = false

    /// Diagnostic surface when the meter cannot start or the configured device is unavailable.
    @Published private(set) var errorMessage: String?

    /// Maximum rate at which smoothed levels are published to the UI.
    private static let publishInterval: TimeInterval = 1.0 / 15.0

    private var audioEngine: AVAudioEngine?
    private var smoothedLevel: Float = 0
    private var lastPublishedAt = Date.distantPast

    private init() {}

    // MARK: - Start / Stop

    func startMonitoring() {
        guard !isMonitoring else { return }

        // Don't access the audio engine if mic permission isn't granted —
        // AVAudioEngine.inputNode implicitly triggers a system mic prompt.
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            errorMessage = micPermissionDeniedMessage
            return
        }
        errorMessage = nil

        let requestedDevice = AppSettings.shared.audioInputDevice
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // Honor the configured input device so the overlay meters the same mic
        // the daemon records from. Resolution failure falls back to the default.
        if !requestedDevice.isEmpty {
            if let deviceID = AudioInputDeviceResolver.deviceID(forName: requestedDevice) {
                do {
                    try inputNode.auAudioUnit.setDeviceID(deviceID)
                } catch {
                    audioLevelLog.error(
                        "Failed to set input device \(requestedDevice): \(error.localizedDescription)"
                    )
                    errorMessage = "The selected microphone is unavailable; metering the default input."
                }
            } else {
                errorMessage = "The selected microphone is unavailable; metering the default input."
            }
        }

        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            errorMessage = "Audio engine reported no usable input format."
            return
        }

        do {
            try engine.start()
        } catch {
            audioLevelLog.error("Failed to start audio engine: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            return
        }

        // Install the tap only after the engine has started successfully, so a
        // failed start doesn't leave an orphaned tap on the input node (which
        // `stopMonitoring()` cannot remove because `self.audioEngine` is nil).
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            let level = Self.normalizedLevel(from: buffer)
            DispatchQueue.main.async {
                self?.update(level: level)
            }
        }

        self.audioEngine = engine
        DispatchQueue.main.async {
            self.isMonitoring = true
        }
    }

    func stopMonitoring() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        smoothedLevel = 0
        lastPublishedAt = .distantPast
        DispatchQueue.main.async {
            self.isMonitoring = false
            self.errorMessage = nil
            self.levels = Array(repeating: 0, count: Self.bandCount)
        }
    }

    // MARK: - Level Processing

    private func update(level newLevel: Float) {
        guard isMonitoring else { return }
        // Exponential moving average gives a stable, pleasing meter.
        smoothedLevel = smoothedLevel * 0.65 + newLevel * 0.35
        let now = Date()
        guard now.timeIntervalSince(lastPublishedAt) >= Self.publishInterval else { return }
        lastPublishedAt = now
        levels = Self.bands(for: smoothedLevel)
    }

    // MARK: - Level Math (internal for tests)

    static let bandWeights: [Float] = [0.7, 0.85, 1.0, 1.1, 1.05, 0.95, 0.8, 0.65]

    static var bandCount: Int {
        bandWeights.count
    }

    /// Perceptually shaped RMS across all channels, normalized to 0...1.
    nonisolated static func normalizedLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        guard channelCount > 0, frameCount > 0 else { return 0 }

        // Mic input is effectively mono — summing every channel over the
        // device-native tap (~43 Hz) is redundant work per buffer. Use the
        // first channel; the energy level is identical for a single source.
        let samples = channelData[0]
        var sum: Float = 0
        for frame in 0..<frameCount {
            let sample = samples[frame]
            sum += sample * sample
        }
        let rootMeanSquare = sqrt(sum / Float(frameCount))
        return pow(min(1, rootMeanSquare * 8), 0.65)
    }

    /// Styled spectrum: one measured level rendered across bands with a fixed
    /// hill-shaped falloff. Deterministic — no random jitter.
    static func bands(for level: Float) -> [Float] {
        let clamped = min(max(level, 0), 1)
        return bandWeights.map { weight in min(1, clamped * weight) }
    }
}

// MARK: - Device Resolution

/// Maps a stored input-device display name to a CoreAudio device. Pure
/// matching logic is separated from CoreAudio interop so it can be tested.
enum AudioInputDeviceResolver {
    /// CoreAudio device ID for a display name, or nil when the name does not
    /// match any currently attached device (caller falls back to default).
    static func deviceID(forName name: String) -> AudioDeviceID? {
        let devices = allInputDevices()
        return selectDevice(forName: name, in: devices)
    }

    /// Selector over attached devices: exact display-name match first, then
    /// case-insensitive. An empty name always resolves to the system default.
    static func selectDevice(forName name: String, in devices: [(id: AudioDeviceID, name: String)]) -> AudioDeviceID? {
        guard !name.isEmpty else { return nil }
        if let match = devices.first(where: { $0.name == name }) {
            return match.id
        }
        return devices.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.id
    }

    private static func allInputDevices() -> [(id: AudioDeviceID, name: String)] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceIDs
        ) == noErr else { return [] }

        return deviceIDs.compactMap { deviceID in
            guard hasInputChannels(deviceID), let name = deviceName(for: deviceID) else { return nil }
            return (deviceID, name)
        }
    }

    private static func deviceName(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString?
        var nameSize = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &nameSize, pointer)
        }
        guard status == noErr, let name else { return nil }
        return name as String
    }

    private static func hasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr else { return false }

        // Layout mirror of AudioBufferList's buffer elements so we can walk
        // the variable-length array without the unavailable Swift helper.
        struct RawAudioBuffer {
            var mData: UnsafeMutableRawPointer?
            var mDataByteSize: UInt32
            var mNumberChannels: UInt32
        }
        let bufferStride = MemoryLayout<UInt32>.size // mNumberBuffers header
        guard dataSize >= UInt32(bufferStride) else { return false }

        let rawBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: bufferStride + Int(dataSize),
            alignment: MemoryLayout<UInt32>.alignment
        )
        defer { rawBuffer.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, rawBuffer) == noErr else { return false }

        let bufferListPointer = rawBuffer.assumingMemoryBound(to: UInt32.self)
        let bufferCount = Int(bufferListPointer.pointee)
        let bufferBase = rawBuffer.advanced(by: bufferStride)
        guard bufferCount > 0 else { return false }

        let buffers = UnsafeBufferPointer<RawAudioBuffer>(
            start: bufferBase.assumingMemoryBound(to: RawAudioBuffer.self),
            count: bufferCount
        )
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }
}

private let micPermissionDeniedMessage = "Microphone access is required to meter audio levels."
