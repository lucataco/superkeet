import Foundation

enum ActionApprovalGrant: Equatable, Hashable, Sendable {
    case exact(toolID: String, argumentsJSON: String)
    case similar(toolID: String, target: String?)

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

    static func supportsSimilar(_ spec: ActionToolSpec, argumentsJSON: String) -> Bool {
        spec.risk == .mutating && target(of: spec, argumentsJSON: argumentsJSON) != nil
    }

    static func target(of spec: ActionToolSpec, argumentsJSON: String) -> String? {
        guard let data = argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let app = (object["app"] as? String) ?? (object["browser"] as? String) ?? (object["app_name"] as? String) {
            let normalized = AppResolver.normalizedName(app)
            return normalized.isEmpty ? nil : "app:\(normalized)"
        }
        if let pid = ActionJSON.integer(object["pid"]) { return "pid:\(pid)" }
        if let bundle = object["bundle_id"] as? String, !bundle.isEmpty { return "bundle:\(bundle)" }
        if let page = object["pageId"] ?? object["page_id"] ?? object["tab_id"] ?? object["target_id"] { return "page:\(page)" }
        return nil
    }

    static func canonical(_ argumentsJSON: String) -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let sorted = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: sorted, encoding: .utf8) else { return argumentsJSON }
        return text
    }
}

struct ActionPlanApprovalRequest: Identifiable, Equatable, Sendable {
    enum Route: Equatable, Sendable {
        case alreadyDone
        case native(spec: ActionToolSpec, argumentsJSON: String)
        case planned

        var isAlreadyDone: Bool { self == .alreadyDone }
    }

    struct Step: Identifiable, Equatable, Sendable {
        let id = UUID()
        let number: Int
        let text: String
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

    var grants: [ActionApprovalGrant] {
        steps.compactMap { step in
            if case .native(let spec, let arguments) = step.route { return .exact(for: spec, argumentsJSON: arguments) }
            return nil
        }
    }

    func needsApproval(under policy: ActionApprovalPolicy) -> Bool {
        steps.contains { step in
            if case .native(let spec, _) = step.route { return policy.requiresApproval(for: spec) }
            return false
        }
    }

    var hasPlannedSteps: Bool {
        steps.contains { $0.route == .planned }
    }
}

enum ActionPlanApprovalDecision: Equatable, Sendable {
    case approveAll
    case stepByStep
    case deny
}
