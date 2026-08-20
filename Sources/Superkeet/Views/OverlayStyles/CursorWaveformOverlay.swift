import SwiftUI

/// Cursor Waveform style: a slim pointer-following pill with a live wave bar.
/// Position is driven by `RecordingOverlayWindowController`; this view only
/// renders the pill contents.
struct CursorWaveformOverlay: View {
    @ObservedObject var audioMonitor: AudioLevelMonitor
    let elapsedTime: TimeInterval
    let isRecording: Bool
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.red)
                .frame(width: 7, height: 7)
                .scaleEffect(isRecording ? 1.2 : 1.0)
                .animation(
                    .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                    value: isRecording
                )

            EqualizerView(
                audioMonitor: audioMonitor,
                barCount: 6,
                barSpacing: 2,
                barWidth: 3,
                maxHeight: 16,
                cornerRadius: 1.5
            )

            Text(formatTime(elapsedTime))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: true, vertical: false)

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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            VisualEffectBlur(material: .hudWindow)
                .clipShape(Capsule())
        )
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 6)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
