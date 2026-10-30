import Foundation

/// What is left to do for a typing clause the final transcript has just confirmed, when the same
/// clause already typed while the speaker was still talking.
///
/// Typed text is never deleted and never typed twice, so the remainder is the only thing that
/// can still be typed.
enum EarlyTypingReconciliation: Equatable, Sendable {
    struct Typing: Equatable, Sendable {
        let app: String
        let text: String
    }

    /// The final text is what was typed, ignoring case.
    case alreadyTyped
    /// The final text continues what was typed. Only the continuation is left.
    case typeRemainder(String)
    /// The final text differs in any other way. Leave what was typed and say so.
    case keepTyped

    static func reconcile(early: Typing, final: Typing) -> EarlyTypingReconciliation {
        guard early.app == final.app else { return .keepTyped }
        let typed = early.text
        if final.text.caseInsensitiveCompare(typed) == .orderedSame { return .alreadyTyped }
        guard let prefix = final.text.range(of: typed, options: [.anchored, .caseInsensitive]) else { return .keepTyped }
        return .typeRemainder(String(final.text[prefix.upperBound...]))
    }

    /// The one line the HUD shows when nothing more is typed.
    static func keptLine(typed: String) -> String {
        "Typed “\(NativeActionExecutor.clip(typed, limit: 40))” early. The final words differed, so nothing more was typed."
    }
}
