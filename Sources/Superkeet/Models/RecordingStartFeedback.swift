import Foundation

/// What a press shows while the speech engine starts, and why a press didn't lead to a
/// recording. Without these a slow or failed start looks like the shortcut was missed.
enum RecordingStartFeedback: Equatable {
    case waitingForEngine
    case microphoneDenied
    case engineFailed
    case notStarted
    case releasedEarly

    /// Spoken by VoiceOver and shown as the menu bar tooltip.
    var status: String {
        switch self {
        case .waitingForEngine: return "Starting speech engine…"
        case .microphoneDenied: return "Microphone access needed"
        case .engineFailed: return "Couldn't start the speech engine. See Settings for details."
        case .notStarted: return "Recording didn't start"
        case .releasedEarly: return "Released before recording started. Hold the shortcut until you hear the start sound."
        }
    }

    /// Shown in the recording overlay, so it must fit its narrowest style.
    var notice: String {
        switch self {
        case .waitingForEngine: return "Getting ready…"
        case .microphoneDenied: return "Mic access needed"
        case .engineFailed: return "Engine didn't start"
        case .notStarted: return "Recording didn't start"
        case .releasedEarly: return "Released too early"
        }
    }
}
