import Foundation
import AVFoundation

/// Monitors microphone audio levels for the equalizer visualization.
/// Uses AVAudioEngine with an input tap, separate from Parakeet's mic capture.
final class AudioLevelMonitor: ObservableObject {
    static let shared = AudioLevelMonitor()

    /// Current audio levels for equalizer bars (0.0 to 1.0), updated at ~30fps
    @Published var levels: [Float] = Array(repeating: 0, count: 8)

    /// Whether monitoring is active
    @Published var isMonitoring: Bool = false

    private var audioEngine: AVAudioEngine?
    private let bandCount = 8
    private let smoothingFactor: Float = 0.3

    private init() {}

    // MARK: - Start / Stop

    func startMonitoring() {
        guard !isMonitoring else { return }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        // Install a tap on the input node
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer)
        }

        do {
            try engine.start()
            self.audioEngine = engine
            DispatchQueue.main.async {
                self.isMonitoring = true
            }
        } catch {
            print("[AudioLevelMonitor] Failed to start audio engine: \(error)")
        }
    }

    func stopMonitoring() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        DispatchQueue.main.async {
            self.isMonitoring = false
            self.levels = Array(repeating: 0, count: self.bandCount)
        }
    }

    // MARK: - Audio Processing

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }

        let frames = Int(buffer.frameLength)
        let data = channelData[0]

        // Divide the buffer into bands and compute RMS for each
        let framesPerBand = max(1, frames / bandCount)
        var newLevels = [Float](repeating: 0, count: bandCount)

        for band in 0..<bandCount {
            let start = band * framesPerBand
            let end = min(start + framesPerBand, frames)
            var sumSquares: Float = 0

            for i in start..<end {
                let sample = data[i]
                sumSquares += sample * sample
            }

            let rms = sqrt(sumSquares / Float(max(1, end - start)))
            // Convert to a 0-1 scale with some amplification for visual appeal
            let level = min(1.0, rms * 5.0)
            newLevels[band] = level
        }

        // Add some frequency-like variation by weighting bands differently
        // (since we don't have real FFT, simulate varying sensitivity)
        let weights: [Float] = [0.7, 0.85, 1.0, 1.1, 1.05, 0.95, 0.8, 0.65]
        for i in 0..<bandCount {
            newLevels[i] *= weights[i]
            // Add slight randomness for more natural look
            newLevels[i] *= Float.random(in: 0.8...1.2)
            newLevels[i] = min(1.0, newLevels[i])
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Smooth the levels for visual appeal
            for i in 0..<self.bandCount {
                self.levels[i] = self.levels[i] * (1 - self.smoothingFactor) + newLevels[i] * self.smoothingFactor
            }
        }
    }
}
