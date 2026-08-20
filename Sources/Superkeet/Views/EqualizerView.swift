import SwiftUI

/// Shared "hot" color ramp + gain used by the recording equalizers so every
/// overlay style stays visually consistent: dim cyan when silent → bright
/// green/yellow → hot red when the mic hears loud audio. Colors are
/// precomputed into a lookup table — at 15 Hz × 8 bars per overlay the
/// alternative (computed HSB + two `Color` allocations per band) allocates
/// over 1,900 objects per second purely for rendering.
enum EqualizerPalette {
    /// Extra gain applied to incoming levels so normal speech reads strongly.
    static let displayGain: CGFloat = 1.6

    /// Quantization steps for the color ramp lookup.
    private static let rampResolution = 32
    private static let colorRamp: [Color] = (0..<rampResolution).map { step in
        let level = CGFloat(step) / CGFloat(rampResolution - 1)
        return makeColor(for: level, withOpacity: true)
    }
    private static let colorRampOpaque: [Color] = (0..<rampResolution).map { step in
        let level = CGFloat(step) / CGFloat(rampResolution - 1)
        return makeColor(for: level, withOpacity: false)
    }

    /// Normalize + gain-boost a raw level into the 0...1 display range.
    static func boostedLevel(_ raw: CGFloat) -> CGFloat {
        min(1, max(0, raw * displayGain))
    }

    /// Heat-map color for a boosted level. Cheap quantized lookup.
    static func color(for level: CGFloat) -> Color {
        let clamped = min(max(level, 0), 1)
        return colorRamp[Int(clamped * CGFloat(rampResolution - 1))]
    }

    /// Shadow color for the same level (opaque — no fade). Lookup-only.
    static func shadowColor(for level: CGFloat) -> Color {
        let clamped = min(max(level, 0), 1)
        return colorRampOpaque[Int(clamped * CGFloat(rampResolution - 1))]
    }

    /// Aggregate level across bands — the "how loud" metric for reactive orbs.
    static func aggregateLevel(_ levels: [Float]) -> CGFloat {
        guard !levels.isEmpty else { return 0 }
        let sum = levels.reduce(0) { $0 + $1 }
        return boostedLevel(CGFloat(sum) / CGFloat(levels.count))
    }

    // MARK: - Ramp construction (called once)

    private static func makeColor(for level: CGFloat, withOpacity: Bool) -> Color {
        let hue = 0.5 - 0.5 * level        // 0.5 cyan -> 0.0 red
        let saturation = 0.85 + 0.15 * level
        let brightness = 0.9 + 0.1 * level
        let opacity = withOpacity ? 0.35 + 0.65 * level : 1.0
        return Color(hue: hue, saturation: saturation, brightness: brightness, opacity: opacity)
    }
}

/// Animated equalizer bars that respond to audio levels.
/// Shares the same hot color ramp and gain as the mini dot equalizer.
/// Sizing parameters let slimmer overlay styles reuse the same rendering.
struct EqualizerView: View {
    @ObservedObject var audioMonitor: AudioLevelMonitor

    var barCount = 8
    var barSpacing: CGFloat = 3
    var barWidth: CGFloat = 4
    var maxHeight: CGFloat = 32
    var cornerRadius: CGFloat = 2

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
                        color: level > 0.2 ? EqualizerPalette.shadowColor(for: level) : .clear,
                        radius: level > 0.2 ? level * 3 : 0
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
                        color: level > 0.2 ? EqualizerPalette.shadowColor(for: level) : .clear,
                        radius: level > 0.2 ? level * 4 : 0
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
