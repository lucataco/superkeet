import AppKit

/// User-facing appearance (theme) choice for the app.
///
/// `system` defers to the macOS system setting (the native default), while
/// `light` and `dark` force a fixed appearance regardless of the OS.
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    /// Human-readable label for the Settings picker.
    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// SF Symbol that visually represents the option.
    var symbolName: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    /// The concrete `NSAppearance` to apply, or `nil` to follow the system.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}
