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
    case alwaysAsk
    case readOnlyAuto
    case autoApprove

    var id: String { rawValue }

    var title: String {
        switch self {
        case .alwaysAsk: return "Ask Before Every Tool"
        case .readOnlyAuto: return "Only Ask Before Changes"
        case .autoApprove: return "Don't Ask"
        }
    }

    var subtitle: String {
        switch self {
        case .alwaysAsk:
            return "Confirm every tool call, including read-only ones."
        case .readOnlyAuto:
            return "Run read-only tools automatically; confirm anything that changes state."
        case .autoApprove:
            return "Run everything without asking, except destructive tools."
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
        case (.autoApprove, .destructive):
            return true
        case (.autoApprove, _):
            return false
        }
    }

    func requiresApproval(for spec: ActionToolSpec) -> Bool {
        requiresApproval(for: spec.risk) && !(self == .readOnlyAuto && spec.approvalExempt)
    }

    /// Flips the menu bar "Auto-Approve Actions" checkbox. Turning it on remembers which asking
    /// policy was active so turning it off restores that choice instead of silently downgrading
    /// "Ask Before Every Tool" to "Only Ask Before Changes".
    static func togglingAutoApprove(
        current: ActionApprovalPolicy,
        remembered: ActionApprovalPolicy?
    ) -> (policy: ActionApprovalPolicy, remembered: ActionApprovalPolicy?) {
        if current == .autoApprove {
            let restored = remembered.flatMap { $0 == .autoApprove ? nil : $0 } ?? .readOnlyAuto
            return (restored, nil)
        }
        return (.autoApprove, current)
    }
}
