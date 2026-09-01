import SwiftUI

/// Wide Notch style: a thin bar that widens the MacBook camera notch sideways
/// without making it taller. When a physical notch is present the shelf renders
/// as two pills flanking it — the center gap is transparent so the hardware
/// cutout shows through. On non-notched screens it collapses to a single pill.
struct NotchShelfOverlay: View {
    @ObservedObject var audioMonitor: AudioLevelMonitor
    @ObservedObject private var layout = RecordingOverlayWindowController.shared
    let elapsedTime: TimeInterval

    var body: some View {
        // The window is the full menu-band height; center content so the pills
        // align vertically with the menu text and the notch.
        Group {
            if layout.notchGapWidth > 0 {
                twoPillBody(gap: layout.notchGapWidth)
            } else {
                singlePillBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Notched: two pills flanking the camera

    /// The window is centered on the notch. Position the two pills so the
    /// transparent gap between them is exactly centered on the camera,
    /// regardless of each pill's content width: left pill's trailing edge at
    /// `center - gap/2`, right pill's leading edge at `center + gap/2`.
    private func twoPillBody(gap: CGFloat) -> some View {
        GeometryReader { geo in
            let center = geo.size.width / 2
            HStack(spacing: 0) {
                // Left pill, trailing-aligned to the gap's left edge.
                HStack {
                    Spacer(minLength: 0)
                    pill { levelBars }
                }
                .frame(width: center - gap / 2)

                // Transparent gap over the camera notch.
                Spacer()
                    .frame(width: gap)

                // Right pill, leading-aligned to the gap's right edge.
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

    // MARK: - Non-notched: one pill

    private var singlePillBody: some View {
        pill {
            HStack(spacing: 10) {
                levelBars
                timerLabel
                levelBars
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
