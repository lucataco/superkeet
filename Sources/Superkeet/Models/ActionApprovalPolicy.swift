import Foundation

enum ActionToolRisk: String, CaseIterable, Identifiable {
    case readOnly
    case mutating
    case destructive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .readOnly: return "Read-only"
        case .mutating: return "Changes state"
        case .destructive: return "Destructive"
        }
    }

    var meansChange: Bool {
        self != .readOnly
    }
}

enum ActionApprovalPolicy: String, CaseIterable, Identifiable {
    case readOnlyAuto
    case alwaysAsk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .readOnlyAuto: return "Only Ask Before Changes"
        case .alwaysAsk: return "Ask Before Every Tool"
        }
    }

    var subtitle: String {
        switch self {
        case .readOnlyAuto:
            return "Run read-only tools automatically; confirm anything that changes state."
        case .alwaysAsk:
            return "Confirm every tool call, including read-only ones."
        }
    }

    func requiresApproval(for risk: ActionToolRisk) -> Bool {
        switch (self, risk) {
        case (.alwaysAsk, _):
            return true
        case (.readOnlyAuto, .readOnly):
            return false
        case (.readOnlyAuto, .mutating), (.readOnlyAuto, .destructive):
            return true
        }
    }
}
