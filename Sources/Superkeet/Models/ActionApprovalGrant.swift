import Foundation

/// Permission the user gave for the rest of one command, so the same kind of
/// call does not ask again. Grants never outlive the command that created them.
enum ActionApprovalGrant: Equatable, Hashable, Sendable {
    /// Exactly this tool with exactly these arguments (a step the user saw in
    /// the plan card).
    case exact(toolID: String, argumentsJSON: String)
    /// This tool again, aimed at the same app or process ("Approve similar").
    case similar(toolID: String, target: String?)

    /// Whether a call is covered. Destructive tools are never covered by a
    /// similarity grant; they always ask.
    func covers(_ spec: ActionToolSpec, argumentsJSON: String) -> Bool {
        switch self {
        case .exact(let toolID, let arguments):
            return toolID == spec.id && Self.canonical(arguments) == Self.canonical(argumentsJSON)
        case .similar(let toolID, let target):
            return toolID == spec.id && spec.risk != .destructive && target == Self.target(of: spec, argumentsJSON: argumentsJSON)
        }
    }

    static func exact(for spec: ActionToolSpec, argumentsJSON: String) -> ActionApprovalGrant {
        .exact(toolID: spec.id, argumentsJSON: canonical(argumentsJSON))
    }

    static func similar(to spec: ActionToolSpec, argumentsJSON: String) -> ActionApprovalGrant {
        .similar(toolID: spec.id, target: target(of: spec, argumentsJSON: argumentsJSON))
    }

    /// Whether "approve similar" makes sense for a call: mutating (not
    /// destructive) and aimed at an identifiable app or process.
    static func supportsSimilar(_ spec: ActionToolSpec, argumentsJSON: String) -> Bool {
        spec.risk == .mutating && target(of: spec, argumentsJSON: argumentsJSON) != nil
    }

    /// The app or process a call is aimed at, from the argument keys computer-use
    /// and browser tools use. `nil` when the call names none.
    static func target(of spec: ActionToolSpec, argumentsJSON: String) -> String? {
        guard let data = argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let app = (object["app"] as? String) ?? (object["browser"] as? String) ?? (object["app_name"] as? String) {
            let normalized = AppResolver.normalizedName(app)
            return normalized.isEmpty ? nil : "app:\(normalized)"
        }
        if let pid = NativeGroundingJSON.integer(object["pid"]) { return "pid:\(pid)" }
        if let bundle = object["bundle_id"] as? String, !bundle.isEmpty { return "bundle:\(bundle)" }
        if let page = object["pageId"] ?? object["page_id"] ?? object["tab_id"] ?? object["target_id"] { return "page:\(page)" }
        return nil
    }

    /// Key-order-independent form so `{"a":1,"b":2}` and `{"b":2,"a":1}` match.
    static func canonical(_ argumentsJSON: String) -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let sorted = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: sorted, encoding: .utf8) else { return argumentsJSON }
        return text
    }
}

/// The plan card: what a compound command is about to do, shown once before
/// any step runs so the user can approve the whole thing in one go.
struct ActionPlanApprovalRequest: Identifiable, Equatable, Sendable {
    enum Route: Equatable, Sendable {
        /// An app opened while the user was speaking already covers this step.
        case alreadyDone
        /// A built-in tool with known arguments; approving the plan approves it.
        case native(spec: ActionToolSpec, argumentsJSON: String)
        /// The on-device planner decides; its tool calls still ask individually.
        case planned

        var isAlreadyDone: Bool { self == .alreadyDone }
    }

    struct Step: Identifiable, Equatable, Sendable {
        let id = UUID()
        let number: Int
        let text: String
        /// Human summary, for example `Press ⌘N in Notes`.
        let summary: String
        let route: Route

        var risk: ActionToolRisk? {
            if case .native(let spec, _) = route { return spec.risk }
            return nil
        }
    }

    let id = UUID()
    let command: String
    let steps: [Step]

    /// The exact grants "Approve All" registers.
    var grants: [ActionApprovalGrant] {
        steps.compactMap { step in
            if case .native(let spec, let arguments) = step.route { return .exact(for: spec, argumentsJSON: arguments) }
            return nil
        }
    }

    /// Whether any shown step would otherwise ask on its own under the policy.
    func needsApproval(under policy: ActionApprovalPolicy) -> Bool {
        steps.contains { step in
            if case .native(let spec, _) = step.route { return policy.requiresApproval(for: spec.risk) }
            return false
        }
    }

    var hasPlannedSteps: Bool {
        steps.contains { $0.route == .planned }
    }
}

enum ActionPlanApprovalDecision: Equatable, Sendable {
    /// Run every shown step without asking again; planned steps' tools still ask.
    case approveAll
    /// Run the plan, asking for each tool call as usual.
    case stepByStep
    case deny
}
