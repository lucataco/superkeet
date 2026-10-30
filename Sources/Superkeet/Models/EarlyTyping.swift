import Foundation

enum EarlyTypingReconciliation: Equatable, Sendable {
    struct Typing: Equatable, Sendable {
        let app: String
        let text: String
    }

    case alreadyTyped
    case typeRemainder(String)
    case keepTyped

    static func reconcile(early: Typing, final: Typing) -> EarlyTypingReconciliation {
        guard early.app == final.app else { return .keepTyped }
        let typed = early.text
        if final.text.caseInsensitiveCompare(typed) == .orderedSame { return .alreadyTyped }
        guard let prefix = final.text.range(of: typed, options: [.anchored, .caseInsensitive]) else { return .keepTyped }
        return .typeRemainder(String(final.text[prefix.upperBound...]))
    }

    static func keptLine(typed: String, final: String) -> String {
        "Typed “\(NativeActionExecutor.clip(typed, limit: 40))” early, not “\(NativeActionExecutor.clip(final, limit: 40))”"
    }
}
