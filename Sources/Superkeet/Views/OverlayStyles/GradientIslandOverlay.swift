import SwiftUI

struct GradientIslandOverlay: View {
    @ObservedObject var audioMonitor: AudioLevelMonitor
    let elapsedTime: TimeInterval
    let isRecording: Bool

    @State private var appeared = false

    var body: some View {
        HStack(spacing: 8) {
            ReactiveOrbView(level: aggregateLevel, isRecording: isRecording)

            Text(OverlayElapsedClock.formatted(elapsedTime))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            VisualEffectBlur(material: .hudWindow)
                .clipShape(Capsule())
        )
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 6)
        .scaleEffect(appeared ? 1 : 0.3)
        .opacity(appeared ? 1 : 0)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: appeared)
        .onAppear { appeared = true }
    }

    private var aggregateLevel: CGFloat {
        EqualizerPalette.aggregateLevel(audioMonitor.levels)
    }
}

private struct ReactiveOrbView: View {
    let level: CGFloat
    let isRecording: Bool

    private var clampedLevel: CGFloat {
        min(max(level, 0), 1)
    }

    var body: some View {
        let hueSweep = 0.75 - 0.35 * clampedLevel
        let gradient = LinearGradient(
            gradient: Gradient(colors: [
                Color(hue: hueSweep, saturation: 0.85, brightness: 1),
                Color(hue: hueSweep + 0.12, saturation: 0.9, brightness: 0.95)
            ]),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        ZStack {
            Circle()
                .fill(gradient)
                .frame(width: 18, height: 18)
            Circle()
                .fill(Color.white.opacity(0.35))
                .frame(width: 8, height: 8)
                .blur(radius: 2)
                .offset(x: -2, y: -2)
        }
        .scaleEffect((isRecording ? 1.0 : 0.8) + clampedLevel * 0.55)
        .shadow(
            color: Color(hue: hueSweep, saturation: 0.9, brightness: 1)
                .opacity(0.4 + 0.6 * clampedLevel),
            radius: 3 + 6 * clampedLevel
        )
        .animation(.spring(response: 0.18, dampingFraction: 0.75), value: clampedLevel)
        .animation(.easeInOut(duration: 0.3), value: isRecording)
    }
}
