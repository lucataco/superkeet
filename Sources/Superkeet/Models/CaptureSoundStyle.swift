import Foundation

/// Audible start/stop feedback for recording, following Nativ's sound-style
/// precedent. `systemCue` reuses macOS's built-in sounds so no bundled
/// assets are needed; `none` keeps feedback visual-only.
enum CaptureSoundStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case systemCue
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .systemCue: return "System Cue"
        case .none: return "No Sound"
        }
    }

    var subtitle: String {
        switch self {
        case .systemCue: return "Play a brief system sound on record start and stop"
        case .none: return "Keep feedback visual only"
        }
    }

    var symbolName: String {
        switch self {
        case .systemCue: return "speaker.wave.2"
        case .none: return "speaker.slash"
        }
    }
}
