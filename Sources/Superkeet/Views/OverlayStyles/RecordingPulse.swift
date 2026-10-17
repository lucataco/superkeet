import SwiftUI

struct RecordingPulse: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The overlay is inserted already recording, so `isRecording` never changes while it is on
    /// screen. Flipping this on appear gives the repeating animation a change to start from.
    @State private var appeared = false
    let isRecording: Bool
    let scale: CGFloat

    func body(content: Content) -> some View {
        let pulsing = appeared && isRecording && !reduceMotion
        content
            .scaleEffect(pulsing ? scale : 1.0)
            .animation(pulsing ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .easeOut(duration: 0.2), value: pulsing)
            .onAppear { appeared = true }
    }
}

extension View {
    func recordingPulse(isRecording: Bool, scale: CGFloat) -> some View {
        modifier(RecordingPulse(isRecording: isRecording, scale: scale))
    }
}
