import XCTest
import AVFoundation
@testable import Superkeet

final class AudioLevelMonitorTests: XCTestCase {

    // MARK: - normalizedLevel

    func testNormalizedLevelIsZeroForEmptyBuffer() throws {
        let buffer = try makeBuffer(sampleValue: 0)
        buffer.frameLength = 0
        XCTAssertEqual(AudioLevelMonitor.normalizedLevel(from: buffer), 0)
    }

    func testNormalizedLevelIsZeroForSilence() throws {
        let buffer = try makeBuffer(sampleValue: 0)
        XCTAssertEqual(AudioLevelMonitor.normalizedLevel(from: buffer), 0)
    }

    func testNormalizedLevelClampsHeavySignalToOne() throws {
        let buffer = try makeBuffer(sampleValue: 1.0)
        XCTAssertEqual(AudioLevelMonitor.normalizedLevel(from: buffer), 1)
    }

    func testNormalizedLevelAppliesPerceptualCurve() throws {
        // RMS = 0.05 -> 0.05 * 8 = 0.4 -> pow(0.4, 0.65) ≈ 0.552
        let buffer = try makeBuffer(sampleValue: 0.05)
        let level = AudioLevelMonitor.normalizedLevel(from: buffer)
        let expected = pow(Float(0.4), Float(0.65))
        XCTAssertEqual(level, expected, accuracy: 0.001)
    }

    // MARK: - bands(for:)

    func testBandsAreDeterministicStylingOfSingleLevel() {
        let bands = AudioLevelMonitor.bands(for: 0.5)
        XCTAssertEqual(bands.count, AudioLevelMonitor.bandWeights.count)
        for (index, weight) in AudioLevelMonitor.bandWeights.enumerated() {
            XCTAssertEqual(bands[index], min(1, 0.5 * weight), accuracy: 0.001)
        }
    }

    func testBandsClampToUnitRange() {
        let bands = AudioLevelMonitor.bands(for: 2)
        for band in bands {
            XCTAssertLessThanOrEqual(band, 1)
            XCTAssertGreaterThanOrEqual(band, 0)
        }
    }

    func testBandsAreSilentForZeroLevel() {
        let bands = AudioLevelMonitor.bands(for: 0)
        XCTAssertTrue(bands.allSatisfy { $0 == 0 })
    }

    // MARK: - Device resolution

    func testSelectDevicePrefersExactMatch() {
        let devices: [(id: AudioDeviceID, name: String)] = [
            (1, "MacBook Air Microphone"),
            (2, "USB Microphone")
        ]
        XCTAssertEqual(AudioInputDeviceResolver.selectDevice(forName: "USB Microphone", in: devices), 2)
    }

    func testSelectDeviceFallsBackToCaseInsensitiveMatch() {
        let devices: [(id: AudioDeviceID, name: String)] = [
            (1, "MacBook Air Microphone"),
            (2, "USB MICROPHONE")
        ]
        XCTAssertEqual(AudioInputDeviceResolver.selectDevice(forName: "usb microphone", in: devices), 2)
    }

    func testSelectDeviceReturnsNilForEmptyName() {
        let devices: [(id: AudioDeviceID, name: String)] = [(1, "Any Mic")]
        XCTAssertNil(AudioInputDeviceResolver.selectDevice(forName: "", in: devices))
    }

    func testSelectDeviceReturnsNilForUnknownName() {
        let devices: [(id: AudioDeviceID, name: String)] = [(1, "Any Mic")]
        XCTAssertNil(AudioInputDeviceResolver.selectDevice(forName: "Missing Mic", in: devices))
    }

    // MARK: - Helpers

    private func makeBuffer(sampleValue: Float) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        buffer.frameLength = 1024
        if let channelData = buffer.floatChannelData {
            for frame in 0..<1024 {
                channelData[0][frame] = sampleValue
            }
        }
        return buffer
    }
}
