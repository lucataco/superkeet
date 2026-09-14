import SwiftUI

struct NotchShelfOverlay: View {
    @ObservedObject var audioMonitor: AudioLevelMonitor
    @ObservedObject private var layout = RecordingOverlayWindowController.shared
    let elapsedTime: TimeInterval

    var body: some View {
        Group {
            if layout.notchGapWidth > 0 {
                twoPillBody(gap: layout.notchGapWidth)
            } else {
                singlePillBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func twoPillBody(gap: CGFloat) -> some View {
        GeometryReader { geo in
            let center = geo.size.width / 2
            HStack(spacing: 0) {
                HStack {
                    Spacer(minLength: 0)
                    pill { levelBars }
                }
                .frame(width: center - gap / 2)

                Spacer()
                    .frame(width: gap)

                HStack {
                    pill {
                        HStack(spacing: 10) {
                            timerLabel
                            levelBars
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: center - gap / 2)
            }
        }
    }

    private var singlePillBody: some View {
        pill {
            HStack(spacing: 10) {
                levelBars
                timerLabel
                levelBars
            }
        }
    }

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
        Text(OverlayElapsedClock.formatted(elapsedTime))
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: true, vertical: false)
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
}
