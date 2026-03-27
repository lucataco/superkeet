import SwiftUI

/// Animated equalizer bars that respond to audio levels (expanded mode)
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
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(barGradient(for: index))
                    .frame(
                        width: barWidth,
                        height: max(4, CGFloat(audioMonitor.levels[index]) * maxHeight)
                    )
                    .animation(
                        .easeInOut(duration: 0.08),
                        value: audioMonitor.levels[index]
                    )
            }
        }
        .frame(height: maxHeight)
    }

    private func barGradient(for index: Int) -> LinearGradient {
        let level = CGFloat(audioMonitor.levels[index])
        let baseColor: Color = level > 0.7 ? .orange : level > 0.4 ? .green : .cyan

        return LinearGradient(
            gradient: Gradient(colors: [
                baseColor.opacity(0.6),
                baseColor
            ]),
            startPoint: .bottom,
            endPoint: .top
        )
    }
}

/// Dot-style equalizer for compact recording overlay — small circles that
/// pulse in size and opacity based on audio levels, matching the Superwhisper style.
/// Uses a fixed width so the layout never collapses when levels are low.
struct DotEqualizerView: View {
    @ObservedObject var audioMonitor: AudioLevelMonitor

    let dotCount = 7
    let dotSpacing: CGFloat = 3
    let dotSize: CGFloat = 5

    var body: some View {
        HStack(spacing: dotSpacing) {
            ForEach(0..<dotCount, id: \.self) { index in
                let level = audioLevel(for: index)
                Circle()
                    .fill(dotColor(for: level))
                    .frame(width: dotSize, height: dotSize)
                    .scaleEffect(0.7 + 0.6 * level)
                    .animation(
                        .easeInOut(duration: 0.1),
                        value: level
                    )
            }
        }
        // Fixed width prevents the HStack from collapsing when dots are small
        .frame(width: CGFloat(dotCount) * dotSize + CGFloat(dotCount - 1) * dotSpacing, height: dotSize * 1.3)
    }

    private func audioLevel(for index: Int) -> CGFloat {
        let mappedIndex = min(index, audioMonitor.levels.count - 1)
        return CGFloat(audioMonitor.levels[mappedIndex])
    }

    private func dotColor(for level: CGFloat) -> Color {
        if level > 0.6 {
            return .cyan
        } else if level > 0.3 {
            return .cyan.opacity(0.8)
        } else {
            return .cyan.opacity(0.5)
        }
    }
}

/// Compact equalizer for the menu bar status area
struct MiniEqualizerView: View {
    @ObservedObject var audioMonitor: AudioLevelMonitor

    let barCount = 4
    let barSpacing: CGFloat = 1.5
    let barWidth: CGFloat = 2
    let maxHeight: CGFloat = 12

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white)
                    .frame(
                        width: barWidth,
                        height: max(2, CGFloat(audioMonitor.levels[index * 2]) * maxHeight)
                    )
                    .animation(
                        .easeInOut(duration: 0.08),
                        value: audioMonitor.levels[index * 2]
                    )
            }
        }
        .frame(height: maxHeight)
    }
}
