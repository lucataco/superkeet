import SwiftUI

struct RecordingPulse: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isRecording: Bool
    let scale: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(isRecording && !reduceMotion ? scale : 1.0)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                value: isRecording
            )
    }
}

extension View {
    func recordingPulse(isRecording: Bool, scale: CGFloat) -> some View {
        modifier(RecordingPulse(isRecording: isRecording, scale: scale))
    }
}
