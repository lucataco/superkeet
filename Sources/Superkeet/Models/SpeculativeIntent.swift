import Foundation

struct SpeculativeApp: Equatable, Sendable {
    let spokenName: String
    let url: URL

    var name: String { url.deletingPathExtension().lastPathComponent }
}

enum SpeculativeAction: Equatable, Sendable {
    case launch(SpeculativeApp)
    case activate(SpeculativeApp)

    var app: SpeculativeApp {
        switch self {
        case .launch(let app), .activate(let app): return app
        }
    }
}

struct SpeculativeCommit: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        case clauseBoundary
        case stable(count: Int)
        case finalized
    }

    let action: SpeculativeAction
    let clause: String
    let sequence: Int
    let reason: Reason
}

struct SpeculativeIntentDetector {
    struct Environment {
        var resolveApp: (String) -> URL?
        var installedNames: () -> [String]
        var isRunning: (URL) -> Bool
    }

    let stabilityThreshold: Int

    private let environment: Environment
    private var cachedNames: [String]?
    private var lastSequence = 0
    private var lastText: String?
    private var lastWasFinal = false
    private var streak: (url: URL, count: Int)?

    private(set) var commit: SpeculativeCommit?
    private(set) var disagreement = false

    init(environment: Environment, stabilityThreshold: Int = 1) {
        self.environment = environment
        self.stabilityThreshold = max(1, stabilityThreshold)
    }

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

    struct Clause: Equatable {
        enum Verb: Equatable {
            case open
            case switchTo
        }

        let verb: Verb
        let candidate: String
        let text: String
        let hasBoundary: Bool
        let containsURL: Bool
    }

    private static let verb = try? NSRegularExpression(
        pattern: #"\A(open(?:\s+up)?|launch|pull\s+up|fire\s+up|start|show\s+me|switch(?:\s+over)?\s+to|activate|bring\s+up|go\s+to)\b\s*(.*)\z"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )
    private static let launchVerbs: Set<String> = ["open", "open up", "launch", "pull up", "fire up", "start", "show me"]
    private static let boundary = try? NSRegularExpression(
        pattern: #"\b(?:and\s+then|and|then|to|so)\b|[,;:\n]|[.?!](?=\s|\z)"#,
        options: .caseInsensitive
    )

    static func leadingClause(in text: String) -> Clause? {
        guard let verbRegex = verb, let boundary else { return nil }
        let working = SpokenURL.normalize(CommandLeadIn.strip(text.lowercased()))
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
        candidate = CommandLeadIn.stripTrailing(candidate.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)))
        guard !candidate.isEmpty else { return nil }

        let tokens = candidate.split(whereSeparator: \.isWhitespace).map { NativeOpenAction.spokenURLToken(String($0)) }
        let containsURL = tokens.contains { token in
            guard !token.hasSuffix(".app") else { return false }
            return token.hasPrefix("http://") || token.hasPrefix("https://") || ActionArgumentNormalizer.normalizedURL(token) != nil
        }
        let verb: Clause.Verb = launchVerbs.contains(verbText) ? .open : .switchTo
        return Clause(verb: verb, candidate: candidate, text: "\(verbText) \(candidate)", hasBoundary: hasBoundary, containsURL: containsURL)
    }

    private func resolveApp(_ clause: Clause) -> SpeculativeApp? {
        let spokenName = AppResolver.normalizedName(clause.candidate)
        guard !spokenName.isEmpty, let url = environment.resolveApp(clause.candidate) else { return nil }
        return SpeculativeApp(spokenName: spokenName, url: url)
    }

    private func action(for clause: Clause, app: SpeculativeApp) -> SpeculativeAction? {
        switch clause.verb {
        case .open: return .launch(app)
        case .switchTo: return environment.isRunning(app.url) ? .activate(app) : nil
        }
    }

    /// Another installed app whose name extends the spoken one ("Safari" while "Safari Technology
    /// Preview" is installed, "Note" while "Notes" is) means the recogniser may still be mid-word,
    /// so a stable sighting alone is not enough to launch.
    private mutating func isAmbiguous(_ app: SpeculativeApp) -> Bool {
        let names = cachedNames ?? environment.installedNames().map(AppResolver.normalizedName)
        cachedNames = names
        let spokenKey = AppResolver.matchKey(app.spokenName)
        let ownKey = AppResolver.matchKey(app.name)
        guard !spokenKey.isEmpty else { return true }
        return names.contains {
            let key = AppResolver.matchKey($0)
            return key != spokenKey && key != ownKey && key.hasPrefix(spokenKey)
        }
    }
}
