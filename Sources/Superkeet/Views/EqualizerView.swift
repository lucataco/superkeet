import SwiftUI

enum EqualizerPalette {
    static let displayGain: CGFloat = 1.6

    private static let rampResolution = 32
    private static let colorRamp: [Color] = (0..<rampResolution).map { step in
        let level = CGFloat(step) / CGFloat(rampResolution - 1)
        return makeColor(for: level, withOpacity: true)
    }
    private static let colorRampOpaque: [Color] = (0..<rampResolution).map { step in
        let level = CGFloat(step) / CGFloat(rampResolution - 1)
        return makeColor(for: level, withOpacity: false)
    }

    static func boostedLevel(_ raw: CGFloat) -> CGFloat {
        min(1, max(0, raw * displayGain))
    }

    static func color(for level: CGFloat) -> Color {
        let clamped = min(max(level, 0), 1)
        return colorRamp[Int(clamped * CGFloat(rampResolution - 1))]
    }

    static func shadowColor(for level: CGFloat) -> Color {
        let clamped = min(max(level, 0), 1)
        return colorRampOpaque[Int(clamped * CGFloat(rampResolution - 1))]
    }

    static func aggregateLevel(_ levels: [Float]) -> CGFloat {
        guard !levels.isEmpty else { return 0 }
        let sum = levels.reduce(0) { $0 + $1 }
        return boostedLevel(CGFloat(sum) / CGFloat(levels.count))
    }

    private static func makeColor(for level: CGFloat, withOpacity: Bool) -> Color {
        let hue = 0.5 - 0.5 * level
        let saturation = 0.85 + 0.15 * level
        let brightness = 0.9 + 0.1 * level
        let opacity = withOpacity ? 0.35 + 0.65 * level : 1.0
        return Color(hue: hue, saturation: saturation, brightness: brightness, opacity: opacity)
    }
}

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

struct DotEqualizerView: View {
    @ObservedObject var audioMonitor: AudioLevelMonitor

    let dotCount = 7
    let dotSpacing: CGFloat = 3
    let dotWidth: CGFloat = 5
    private var minHeight: CGFloat { dotWidth }
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
        .frame(
            width: CGFloat(dotCount) * dotWidth + CGFloat(dotCount - 1) * dotSpacing,
            height: maxHeight
        )
    }

    private func audioLevel(for index: Int) -> CGFloat {
        let mappedIndex = min(index, audioMonitor.levels.count - 1)
        return EqualizerPalette.boostedLevel(CGFloat(audioMonitor.levels[mappedIndex]))
    }

    private func dotHeight(for level: CGFloat) -> CGFloat {
        minHeight + (maxHeight - minHeight) * level
    }
}
