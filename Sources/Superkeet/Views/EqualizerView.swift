import SwiftUI

/// Shared "hot" color ramp + gain used by the recording equalizers so the dot
/// (mini) and bar (classic) styles stay visually consistent: dim cyan when
/// silent → bright green/yellow → hot red when the mic hears loud audio.
private enum EqualizerPalette {
    /// Extra gain applied to incoming levels so normal speech reads strongly.
    static let displayGain: CGFloat = 1.6

    /// Normalize + gain-boost a raw level into the 0...1 display range.
    static func boostedLevel(_ raw: CGFloat) -> CGFloat {
        min(1, max(0, raw * displayGain))
    }

    /// Heat-map color that exaggerates with level.
    static func color(for level: CGFloat) -> Color {
        let clamped = min(max(level, 0), 1)
        let hue = 0.5 - 0.5 * clamped        // 0.5 cyan -> 0.0 red
        let saturation = 0.85 + 0.15 * clamped
        let brightness = 0.9 + 0.1 * clamped
        let opacity = 0.35 + 0.65 * clamped  // faint when silent, vivid when loud
        return Color(hue: hue, saturation: saturation, brightness: brightness, opacity: opacity)
    }
}

/// Animated equalizer bars that respond to audio levels (expanded mode).
/// Shares the same hot color ramp and gain as the mini dot equalizer.
struct EqualizerView: View {
    @ObservedObject var audioMonitor: AudioLevelMonitor

    let barCount = 8
    let barSpacing: CGFloat = 3
    let barWidth: CGFloat = 4
    let maxHeight: CGFloat = 32
    let cornerRadius: CGFloat = 2

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { index in
                let level = EqualizerPalette.boostedLevel(CGFloat(audioMonitor.levels[index]))
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(barGradient(for: level))
                    .frame(
                        width: barWidth,
                        height: max(4, level * maxHeight)
                    )
                    .shadow(
                        color: EqualizerPalette.color(for: level).opacity(Double(level) * 0.8),
                        radius: level * 3
                    )
                    .animation(
                        .easeOut(duration: 0.08),
                        value: level
                    )
            }
        }
        .frame(height: maxHeight)
    }

    private func barGradient(for level: CGFloat) -> LinearGradient {
        // Slightly cooler/dimmer at the base, vivid at the tip.
        return LinearGradient(
            gradient: Gradient(colors: [
                EqualizerPalette.color(for: level * 0.65),
                EqualizerPalette.color(for: level)
            ]),
            startPoint: .bottom,
            endPoint: .top
        )
    }
}

/// Dot-style equalizer for compact recording overlay — capsules that sit as
/// small dots when idle and stretch tall while shifting through a hot color
/// ramp as soon as the mic picks up the user's voice. The exaggerated height
/// and color make it obvious that audio is being heard.
struct DotEqualizerView: View {
    @ObservedObject var audioMonitor: AudioLevelMonitor

    let dotCount = 7
    let dotSpacing: CGFloat = 3
    /// Width of each capsule (also the diameter of the resting dot).
    let dotWidth: CGFloat = 5
    /// Resting height — a round dot when there's no audio.
    private var minHeight: CGFloat { dotWidth }
    /// Fully stretched height when the mic hears loud audio.
    let maxHeight: CGFloat = 18

    var body: some View {
        HStack(spacing: dotSpacing) {
            ForEach(0..<dotCount, id: \.self) { index in
                let level = audioLevel(for: index)
                Capsule()
                    .fill(EqualizerPalette.color(for: level))
                    .frame(width: dotWidth, height: dotHeight(for: level))
                    .shadow(
                        color: EqualizerPalette.color(for: level).opacity(Double(level) * 0.9),
                        radius: level * 4
                    )
                    .animation(
                        .easeOut(duration: 0.1),
                        value: level
                    )
            }
        }
        // Fixed size keeps the pill layout stable as capsules grow/shrink.
        .frame(
            width: CGFloat(dotCount) * dotWidth + CGFloat(dotCount - 1) * dotSpacing,
            height: maxHeight
        )
    }

    /// Normalized, gain-boosted level (0...1) for a given dot.
    private func audioLevel(for index: Int) -> CGFloat {
        let mappedIndex = min(index, audioMonitor.levels.count - 1)
        return EqualizerPalette.boostedLevel(CGFloat(audioMonitor.levels[mappedIndex]))
    }

    /// Stretches from a small resting dot up to a tall pill with the level.
    private func dotHeight(for level: CGFloat) -> CGFloat {
        minHeight + (maxHeight - minHeight) * level
    }
}
