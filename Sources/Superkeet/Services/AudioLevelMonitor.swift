import Foundation
import AVFoundation
import CoreAudio

@MainActor
final class AudioLevelMonitor: ObservableObject {
    static let shared = AudioLevelMonitor()

    @Published private(set) var levels: [Float] = Array(repeating: 0, count: 8)

    @Published private(set) var isMonitoring: Bool = false

    @Published private(set) var errorMessage: String?

    private static let publishInterval: TimeInterval = 1.0 / 15.0

    private let hub: MicrophoneTapHub
    private var subscription: MicrophoneTapHub.Subscription?
    private var smoothedLevel: Float = 0
    private var lastPublishedAt = Date.distantPast

    init(hub: MicrophoneTapHub? = nil) {
        self.hub = hub ?? .shared
    }

    func startMonitoring() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isMonitoring else { return }

        do {
            subscription = try hub.subscribe { [weak self] buffer, _ in
                let level = Self.normalizedLevel(from: buffer)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.update(level: level) }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        errorMessage = hub.warning
        isMonitoring = true
    }

    func stopMonitoring() {
        dispatchPrecondition(condition: .onQueue(.main))
        if let subscription { hub.unsubscribe(subscription) }
        subscription = nil
        smoothedLevel = 0
        lastPublishedAt = .distantPast
        isMonitoring = false
        errorMessage = nil
        levels = Array(repeating: 0, count: Self.bandCount)
    }

    private func update(level newLevel: Float) {
        guard isMonitoring else { return }
        smoothedLevel = smoothedLevel * 0.65 + newLevel * 0.35
        let now = Date()
        guard now.timeIntervalSince(lastPublishedAt) >= Self.publishInterval else { return }
        lastPublishedAt = now
        levels = Self.bands(for: smoothedLevel)
    }

    nonisolated static let bandWeights: [Float] = [0.7, 0.85, 1.0, 1.1, 1.05, 0.95, 0.8, 0.65]

    nonisolated static var bandCount: Int {
        bandWeights.count
    }

    nonisolated static func normalizedLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        guard channelCount > 0, frameCount > 0 else { return 0 }

        let samples = channelData[0]
        var sum: Float = 0
        for frame in 0..<frameCount {
            let sample = samples[frame]
            sum += sample * sample
        }
        let rootMeanSquare = sqrt(sum / Float(frameCount))
        return pow(min(1, rootMeanSquare * 8), 0.65)
    }

    nonisolated static func bands(for level: Float) -> [Float] {
        let clamped = min(max(level, 0), 1)
        return bandWeights.map { weight in min(1, clamped * weight) }
    }
}

enum AudioInputDeviceResolver {
    static func availableDeviceNames() -> [String] {
        deviceNames(in: allInputDevices())
    }

    static func deviceNames(in devices: [(id: AudioDeviceID, name: String)]) -> [String] {
        Array(Set(devices.map { $0.name })).sorted()
    }

    static func deviceID(forName name: String) -> AudioDeviceID? {
        let devices = allInputDevices()
        return selectDevice(forName: name, in: devices)
    }

    static func namesMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    static func selectDevice(forName name: String, in devices: [(id: AudioDeviceID, name: String)]) -> AudioDeviceID? {
        guard !name.isEmpty else { return nil }
        if let match = devices.first(where: { $0.name == name }) {
            return match.id
        }
        return devices.first(where: { namesMatch(name, $0.name) })?.id
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
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfName: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &cfName) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, pointer)
        }
        guard status == noErr, let cfName else { return nil }
        return cfName.takeUnretainedValue() as String
    }

    private static func hasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return false }

        let rawBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawBuffer.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, rawBuffer) == noErr else {
            return false
        }

        let bufferList = rawBuffer.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.contains { $0.mNumberChannels > 0 }
    }
}
