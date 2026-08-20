import Foundation

/// User-facing recording-overlay style choice.
///
/// Persisted as a raw string in `AppSettings.recordingOverlayStyle`, so legacy
/// values ("mini", "classic", "none") resolve without migration. Unknown or
/// stale values fall back to `.mini`.
enum OverlayAnimationStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case mini
    case classic
    case cursorWaveform
    case gradientIsland
    case notchShelf
    case none

    var id: String { rawValue }

    /// Safe resolution of a persisted raw value; invalid entries fall back to mini.
    static func resolve(_ stored: String) -> OverlayAnimationStyle {
        OverlayAnimationStyle(rawValue: stored) ?? .mini
    }

    /// Styles that render an overlay (picker excludes "none" from live preview).
    var showsOverlay: Bool {
        self != .none
    }

    var title: String {
        switch self {
        case .mini: return "Mini"
        case .classic: return "Classic"
        case .cursorWaveform: return "Cursor Waveform"
        case .gradientIsland: return "Gradient Island"
        case .notchShelf: return "Wide Notch"
        case .none: return "None"
        }
    }

    var subtitle: String {
        switch self {
        case .mini: return "Compact dot pill"
        case .classic: return "Expanded bar equalizer"
        case .cursorWaveform: return "Live waveform that follows your pointer"
        case .gradientIsland: return "Liquid-glass reactive orb with start cues"
        case .notchShelf: return "Widens the MacBook notch without growing taller"
        case .none: return "No overlay"
        }
    }

    /// Where the overlay anchors, shown as the card's location chip.
    var locationLabel: String {
        switch self {
        case .mini, .classic: return "Bottom center"
        case .cursorWaveform: return "At pointer"
        case .gradientIsland: return "Beside camera"
        case .notchShelf: return "Around camera"
        case .none: return "Hidden"
        }
    }

    var symbolName: String {
        switch self {
        case .mini: return "ellipsis"
        case .classic: return "waveform.path"
        case .cursorWaveform: return "waveform"
        case .gradientIsland: return "circle.fill"
        case .notchShelf: return "rectangle.topthird.inset.filled"
        case .none: return "eye.slash"
        }
    }
}
