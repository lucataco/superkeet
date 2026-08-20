import SwiftUI

/// Wide Notch style: a thin bar that widens the MacBook camera notch sideways
/// without making it taller. When a physical notch is present the shelf renders
/// as two pills flanking it — the center gap is transparent so the hardware
/// cutout shows through. On non-notched screens it collapses to a single pill.
struct NotchShelfOverlay: View {
    @ObservedObject var audioMonitor: AudioLevelMonitor
    @ObservedObject private var layout = RecordingOverlayWindowController.shared
    let elapsedTime: TimeInterval
    let isRecording: Bool
    let onStop: () -> Void

    var body: some View {
        if layout.notchGapWidth > 0 {
            twoPillBody(gap: layout.notchGapWidth)
        } else {
            singlePillBody
        }
    }

    // MARK: - Notched: two pills flanking the camera

    private func twoPillBody(gap: CGFloat) -> some View {
        HStack(spacing: 0) {
            pill {
                levelBars
            }
            Spacer()
                .frame(width: gap)
            pill {
                HStack(spacing: 10) {
                    timerLabel
                    levelBars
                    stopButton
                }
            }
        }
    }

    // MARK: - Non-notched: one pill

    private var singlePillBody: some View {
        pill {
            HStack(spacing: 10) {
                levelBars
                timerLabel
                levelBars
                stopButton
            }
        }
    }

    // MARK: - Components

    private var levelBars: some View {
        EqualizerView(
            audioMonitor: audioMonitor,
            barCount: 5,
            barSpacing: 2,
            barWidth: 3,
            maxHeight: 16,
            cornerRadius: 1.5
        )
    }

    private var timerLabel: some View {
        Text(formatTime(elapsedTime))
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var stopButton: some View {
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

    private func pill<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                VisualEffectBlur(material: .hudWindow)
                    .clipShape(Capsule())
            )
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
