import Foundation

/// An installed app named in a spoken clause.
struct SpeculativeApp: Equatable, Sendable {
    /// The normalized spoken reference, for example "notes" for "the Notes app".
    let spokenName: String
    let url: URL

    var name: String { url.deletingPathExtension().lastPathComponent }
}

/// What may run before the final transcript arrives. Both are low risk: a
/// misheard name either resolves to nothing or opens an installed app.
enum SpeculativeAction: Equatable, Sendable {
    /// "open X" / "launch X". Opening a running app brings it to the front.
    case launch(SpeculativeApp)
    /// "switch to X" for an app that is already running.
    case activate(SpeculativeApp)

    var app: SpeculativeApp {
        switch self {
        case .launch(let app), .activate(let app): return app
        }
    }
}

/// The single decision a detector makes for one recording session.
struct SpeculativeCommit: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        /// A conjunction or separator followed the app name, so the clause is complete.
        case clauseBoundary
        /// The same app was heard in this many consecutive partials and no other
        /// installed name could extend it.
        case stable(count: Int)
        /// The recogniser finalized the phrase.
        case finalized
    }

    let action: SpeculativeAction
    /// The clause that named the app, lowercased, for example "open the notes app".
    let clause: String
    /// Sequence number of the partial that triggered the commit.
    let sequence: Int
    let reason: Reason
}

/// Watches the running text of a Command Mode recording and decides, at most
/// once per session, that an app should open or come to the front right away.
///
/// Everything here is deterministic string handling plus an injected installed-app
/// lookup, so it is fully testable with scripted partials. It never undoes a
/// decision: if later text disagrees, `disagreement` is set for the caller to
/// surface, and the final transcript still drives the real command.
struct SpeculativeIntentDetector {
    struct Environment {
        /// Resolves a spoken app reference to an installed bundle, or `nil`.
        var resolveApp: (String) -> URL?
        /// Display names of every installed app, used to detect prefixes such as
        /// "Safari" versus "Safari Technology Preview".
        var installedNames: () -> [String]
        /// Whether the app at this bundle URL is currently running.
        var isRunning: (URL) -> Bool
    }

    /// Consecutive partials that must name the same app before it is trusted
    /// without a clause boundary or a finalized result.
    let stabilityThreshold: Int

    private let environment: Environment
    private var cachedNames: [String]?
    private var lastSequence = 0
    private var lastText: String?
    private var lastWasFinal = false
    private var streak: (url: URL, count: Int)?

    private(set) var commit: SpeculativeCommit?
    /// Set once text observed after the commit names a different app, or the
    /// finalized text no longer names the committed one.
    private(set) var disagreement = false

    init(environment: Environment, stabilityThreshold: Int = 2) {
        self.environment = environment
        self.stabilityThreshold = max(1, stabilityThreshold)
    }

    /// Feeds one partial and returns the commit if this partial produced it.
    /// Out-of-order and repeated partials are ignored.
    mutating func observe(_ partial: PartialTranscript) -> SpeculativeCommit? {
        guard partial.sequence > lastSequence else { return nil }
        lastSequence = partial.sequence
        guard partial.text != lastText || partial.isFinal != lastWasFinal else { return nil }
        lastText = partial.text
        lastWasFinal = partial.isFinal

        guard ActiveTabIntent.extract(partial.text) == nil,
              let clause = Self.leadingClause(in: partial.text), !clause.containsURL,
              let app = resolveApp(clause) else {
            streak = nil
            if commit != nil, partial.isFinal { disagreement = true }
            return nil
        }

        if let commit {
            if app.url != commit.action.app.url { disagreement = true }
            return nil
        }

        guard let action = action(for: clause, app: app) else {
            streak = nil
            return nil
        }

        if let current = streak, current.url == app.url {
            streak = (app.url, current.count + 1)
        } else {
            streak = (app.url, 1)
        }

        let reason: SpeculativeCommit.Reason
        if partial.isFinal {
            reason = .finalized
        } else if clause.hasBoundary {
            reason = .clauseBoundary
        } else if let count = streak?.count, count >= stabilityThreshold, !isAmbiguous(app) {
            reason = .stable(count: count)
        } else {
            return nil
        }

        let commit = SpeculativeCommit(action: action, clause: clause.text, sequence: partial.sequence, reason: reason)
        self.commit = commit
        return commit
    }

    mutating func reset() {
        lastSequence = 0
        lastText = nil
        lastWasFinal = false
        streak = nil
        commit = nil
        disagreement = false
    }

    // MARK: Clause parsing

    struct Clause: Equatable {
        enum Verb: Equatable {
            case open
            case switchTo
        }

        let verb: Verb
        /// Spoken app reference between the verb and the clause boundary.
        let candidate: String
        /// Verb plus candidate, lowercased.
        let text: String
        /// Whether a conjunction or separator followed the candidate.
        let hasBoundary: Bool
        /// Whether the candidate contains a web address; those are URL opens, not app launches.
        let containsURL: Bool
    }

    private static let fillers = try? NSRegularExpression(
        pattern: #"\A(?:(?:hey|hi|ok|okay|please|um|uh|so|now|just|superkeet|can you|could you|would you|will you)\b[,\s]*)+"#,
        options: .caseInsensitive
    )
    private static let verb = try? NSRegularExpression(
        pattern: #"\A(open(?:\s+up)?|launch|switch(?:\s+over)?\s+to|activate|bring\s+up|go\s+to)\b\s*(.*)\z"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )
    private static let boundary = try? NSRegularExpression(
        pattern: #"\b(?:and\s+then|and|then|to|so)\b|[,;:\n]|\.(?=\s|\z)"#,
        options: .caseInsensitive
    )

    /// Parses the opening clause of a spoken command when it starts with an
    /// open or switch verb, after skipping leading filler words.
    static func leadingClause(in text: String) -> Clause? {
        guard let fillers, let verbRegex = verb, let boundary else { return nil }
        var working = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = fillers.firstMatch(in: working, range: NSRange(working.startIndex..., in: working)),
           let range = Range(match.range, in: working) {
            working.removeSubrange(range)
        }
        guard let match = verbRegex.firstMatch(in: working, range: NSRange(working.startIndex..., in: working)),
              let verbRange = Range(match.range(at: 1), in: working),
              let restRange = Range(match.range(at: 2), in: working) else { return nil }
        let verbText = working[verbRange].split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let rest = String(working[restRange])

        var candidate = rest
        var hasBoundary = false
        if let stop = boundary.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)),
           let stopRange = Range(stop.range, in: rest) {
            candidate = String(rest[..<stopRange.lowerBound])
            hasBoundary = true
        }
        candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !candidate.isEmpty else { return nil }

        let tokens = candidate.split(whereSeparator: \.isWhitespace).map { NativeOpenAction.spokenURLToken(String($0)) }
        let containsURL = tokens.contains { token in
            // ".app" is a real top-level domain, but in a spoken command it names an application bundle.
            guard !token.hasSuffix(".app") else { return false }
            return token.hasPrefix("http://") || token.hasPrefix("https://") || ActionArgumentNormalizer.normalizedURL(token) != nil
        }
        let verb: Clause.Verb = ["open", "open up", "launch"].contains(verbText) ? .open : .switchTo
        return Clause(verb: verb, candidate: candidate, text: "\(verbText) \(candidate)", hasBoundary: hasBoundary, containsURL: containsURL)
    }

    // MARK: Resolution

    private func resolveApp(_ clause: Clause) -> SpeculativeApp? {
        let spokenName = AppResolver.normalizedName(clause.candidate)
        guard !spokenName.isEmpty, let url = environment.resolveApp(clause.candidate) else { return nil }
        return SpeculativeApp(spokenName: spokenName, url: url)
    }

    /// "switch to" only applies to a running app; a stopped app is left to the
    /// real command so the detector never launches something the user meant to
    /// merely bring forward.
    private func action(for clause: Clause, app: SpeculativeApp) -> SpeculativeAction? {
        switch clause.verb {
        case .open: return .launch(app)
        case .switchTo: return environment.isRunning(app.url) ? .activate(app) : nil
        }
    }

    /// Whether another installed app's name begins with the spoken name, in
    /// which case the user may not have finished saying it.
    private mutating func isAmbiguous(_ app: SpeculativeApp) -> Bool {
        let names = cachedNames ?? environment.installedNames().map(AppResolver.normalizedName)
        cachedNames = names
        let own = AppResolver.normalizedName(app.name)
        let prefix = app.spokenName + " "
        return names.contains { $0 != app.spokenName && $0 != own && $0.hasPrefix(prefix) }
    }
}
