import Foundation

/// Which model, if any, reads a clause the native routes did not recognise before it is handed
/// to the planner.
enum IntentRouterChoice: String, CaseIterable, Identifiable, Sendable {
    case off
    case onDevice
    case decisionModel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .onDevice: return "On-Device Model"
        case .decisionModel: return "Local Decision Model (Ollama)"
        }
    }

    var subtitle: String {
        switch self {
        case .off:
            return "Only exact phrasings run directly. Everything else is planned step by step, which is slower."
        case .onDevice:
            return "Apple Intelligence reads loosely worded commands such as “I need the calculator”. About one second."
        case .decisionModel:
            return "A decision model served by Ollama on this Mac reads them. More accurate, one to two seconds, and it needs the model loaded."
        }
    }
}
