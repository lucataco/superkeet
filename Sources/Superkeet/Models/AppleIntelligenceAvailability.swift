import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

enum AppleIntelligenceAvailability: Equatable {
    case available
    case unavailable(String)
    case requiresNewerOS

    static var current: AppleIntelligenceAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                return .unavailable(String(describing: reason))
            @unknown default:
                return .unavailable("Unknown reason")
            }
        }
        #endif
        return .requiresNewerOS
    }

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    /// Whether this Mac can run Actions Mode at all. Cheap (no model query); use it to decide
    /// whether to show Actions UI. When true but `current` is unavailable, show the UI with a
    /// prompt to enable Apple Intelligence instead of hiding the feature.
    static var osSupportsActionsMode: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return true }
        #endif
        return false
    }

    var detail: String {
        switch self {
        case .available:
            return "Apple Intelligence is available for Actions Mode."
        case .unavailable(let reason):
            return "Apple Intelligence is unavailable: \(reason)"
        case .requiresNewerOS:
            return "Actions Mode requires macOS 26 with Apple Intelligence."
        }
    }
}
