import Foundation

/// Everything the compact Actions pill needs to decide what to show, as plain values.
struct ActionPillState: Equatable {
    var compactEnabled = true
    var hasQuestion = false
    var userExpanded = false
    var phase = AgentSessionController.Phase.idle
    var isSessionActive = false
    /// The transcript of the take in progress; `nil` when no take is open.
    var transcript: String?
    var runningStep: String?
    var liveMessage = ""
    /// A just-finished action, shown for a moment (see `ActionPillContent.confirmationDuration`).
    var confirmation: String?
    var failure: String?
    /// What the planner said when a step ended in words rather than an action.
    var reply: String?

    var isListening: Bool { isSessionActive || transcript != nil }
}

/// What the compact pill shows: one glyph and one line of text.
struct ActionPillContent: Equatable {
    enum Glyph: Equatable {
        case bars(active: Bool)
        case spinner
        case check
        case warning
    }

    enum Tone: Equatable {
        case placeholder
        case normal
        case warning
    }

    enum Presentation: Equatable {
        case pill(ActionPillContent)
        case card

        var isPill: Bool { self != .card }
    }

    static let sessionPlaceholder = "Go ahead, I’m listening…"
    static let takePlaceholder = "Say a command…"
    static let workingFallback = "Working…"
    static let confirmationDuration: TimeInterval = 1.2
    static let failureDuration: TimeInterval = 4
    /// A spoken-style answer takes longer to read than "Opened Notes".
    static let replyDuration: TimeInterval = 5
    static let tickerCharacterLimit = 120
    /// About what fits in the pill; longer "Step: reason" lines keep just the reason.
    static let failureLineLimit = 44

    var glyph: Glyph
    var text: String
    var tone: Tone = .normal
    /// A ticker keeps the tail of the words visible and fades the left edge.
    var isTicker = false
    /// A finished action shown beside the ticker while the user keeps talking.
    var checkBeside: String?

    static func presentation(for state: ActionPillState) -> Presentation {
        if !state.compactEnabled || state.hasQuestion || state.userExpanded { return .card }
        if case .failed = state.phase, !state.isListening { return .card }

        if let words = state.transcript.map(collapsedWhitespace), !words.isEmpty {
            return .pill(ActionPillContent(
                glyph: .bars(active: true), text: tickerTail(words), isTicker: true, checkBeside: state.confirmation
            ))
        }
        if let failure = state.failure {
            return .pill(ActionPillContent(glyph: .warning, text: failure, tone: .warning))
        }
        if let confirmation = state.confirmation {
            return .pill(ActionPillContent(glyph: .check, text: confirmation))
        }
        if state.phase.isActive {
            let message = state.liveMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            return .pill(ActionPillContent(glyph: .spinner, text: state.runningStep ?? (message.isEmpty ? workingFallback : message)))
        }
        if case .finished = state.phase {
            // An answer is not a completed action, so it gets no check.
            if let reply = state.reply { return .pill(ActionPillContent(glyph: .bars(active: false), text: reply)) }
            return .pill(ActionPillContent(glyph: .check, text: "Done"))
        }
        let placeholder = state.isSessionActive ? sessionPlaceholder : takePlaceholder
        return .pill(ActionPillContent(glyph: .bars(active: false), text: placeholder, tone: .placeholder))
    }

    /// The end of what was heard. The view right-aligns it and clips the left edge, so this only
    /// bounds the work; it starts on a word boundary when one is close enough.
    static func tickerTail(_ text: String, limit: Int = tickerCharacterLimit) -> String {
        let words = collapsedWhitespace(text)
        guard limit > 0, words.count > limit else { return words }
        let tail = words.suffix(limit)
        if let space = tail.firstIndex(of: " "), tail.distance(from: tail.startIndex, to: space) < limit / 3 {
            return String(tail[tail.index(after: space)...])
        }
        return String(tail)
    }

    /// The newest finished line the pill has not confirmed yet.
    static func newlyDone(in lines: [ActionLine], seen: Set<String>) -> String? {
        lines.last { $0.status == .done && !seen.contains($0.title) }?.title
    }

    static func doneTitles(in lines: [ActionLine]) -> Set<String> {
        Set(lines.filter { $0.status == .done }.map(\.title))
    }

    static func runningStep(in lines: [ActionLine]) -> String? {
        lines.last { $0.status == .running }?.title
    }

    /// One short line for a failed command: the step that failed and why.
    static func failureLine(checklist: ActionChecklist, message: String) -> String {
        if let failed = checklist.lines.last(where: { if case .failed = $0.status { return true } else { return false } }) {
            if let reason = failed.reason {
                let line = "\(failed.title): \(reason)"
                return line.count <= failureLineLimit ? line : reason
            }
            return "\(failed.title) didn’t work"
        }
        if let denied = checklist.lines.last(where: { $0.status == .denied }) {
            return "\(denied.title): not approved"
        }
        return ActionLineText.reason(from: message) ?? checklist.failureTitle
    }

    /// The first sentence of the planner's latest answer, which is what fits on one line. The
    /// card shows all of it.
    static func replyLine(in checklist: ActionChecklist) -> String? {
        guard let reply = checklist.replies.last else { return nil }
        return ActionLineText.reason(from: reply) ?? collapsedWhitespace(reply)
    }

    private static func collapsedWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
