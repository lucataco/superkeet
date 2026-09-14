import Foundation

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

    var symbolName: String {
        switch self {
        case .systemCue: return "speaker.wave.2"
        case .none: return "speaker.slash"
        }
    }
}
