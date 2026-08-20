import SwiftUI

/// Wide Notch style: a thin bar that widens the MacBook camera notch sideways
/// without making it taller. Level bars cluster left and right of a fixed
/// center gap that sits over the physical notch.
struct NotchShelfOverlay: View {
    @ObservedObject var audioMonitor: AudioLevelMonitor
    let elapsedTime: TimeInterval
    let isRecording: Bool
    let onStop: () -> Void

    /// Reserved transparent span over the physical camera notch.
    private let notchGapWidth: CGFloat = 108

    var body: some View {
        HStack(spacing: 10) {
            EqualizerView(
                audioMonitor: audioMonitor,
                barCount: 5,
                barSpacing: 2,
                barWidth: 3,
                maxHeight: 16,
                cornerRadius: 1.5
            )

            Spacer(minLength: notchGapWidth)

            Text(formatTime(elapsedTime))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: true, vertical: false)

            EqualizerView(
                audioMonitor: audioMonitor,
                barCount: 5,
                barSpacing: 2,
                barWidth: 3,
                maxHeight: 16,
                cornerRadius: 1.5
            )

            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.white)
                    .frame(width: 20, height: 20)
                    .background(Color.primary.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(
            VisualEffectBlur(material: .hudWindow)
                .clipShape(Capsule())
        )
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 6)
        .animation(
            .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
            value: isRecording
        )
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
