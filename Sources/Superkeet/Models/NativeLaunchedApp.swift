import Foundation

/// What a native `open_app` produced. Later steps (and the planner) can target
/// the app by pid without a separate discovery round-trip, and the planner
/// learns whether a window is already there to observe.
struct NativeLaunchedApp: Equatable, Sendable {
    let name: String
    let bundleIdentifier: String?
    let processIdentifier: Int32
    let windowReady: Bool

    private static let windowReadyText = "Its window is on screen."
    private static let windowPendingText = "No window has appeared yet."

    /// Model- and user-facing result of an `open_app` step. The format is fixed
    /// so `init(summary:)` can recover the launch from a tool result string.
    var summary: String {
        var details = ["pid \(processIdentifier)"]
        if let bundleIdentifier, !bundleIdentifier.isEmpty { details.append(bundleIdentifier) }
        let state = windowReady ? Self.windowReadyText : Self.windowPendingText
        return "Opened \(name) (\(details.joined(separator: ", "))). \(state)"
    }

    private static let summaryPattern = try? NSRegularExpression(
        pattern: #"\AOpened (.+) \(pid (\d+)(?:, ([^)]+))?\)\. (.+)\z"#, options: .dotMatchesLineSeparators
    )

    /// Recovers a launch from its `summary`, or `nil` for any other text.
    init?(summary: String) {
        guard let pattern = Self.summaryPattern,
              let match = pattern.firstMatch(in: summary, range: NSRange(summary.startIndex..., in: summary)),
              let nameRange = Range(match.range(at: 1), in: summary),
              let pidRange = Range(match.range(at: 2), in: summary),
              let pid = Int32(summary[pidRange]),
              let stateRange = Range(match.range(at: 4), in: summary) else { return nil }
        let state = String(summary[stateRange])
        guard state == Self.windowReadyText || state == Self.windowPendingText else { return nil }
        self.name = String(summary[nameRange])
        self.bundleIdentifier = Range(match.range(at: 3), in: summary).map { String(summary[$0]) }
        self.processIdentifier = pid
        self.windowReady = state == Self.windowReadyText
    }

    init(name: String, bundleIdentifier: String?, processIdentifier: Int32, windowReady: Bool) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.windowReady = windowReady
    }
}

/// Bounded wait for a freshly opened app to finish launching and show a window,
/// so the next observation sees it instead of an empty desktop. It never fails:
/// some apps legitimately open without a window, so the outcome is reported
/// rather than thrown. Cancellation propagates.
@MainActor
struct NativeLaunchWaiter {
    var timeout: Duration = .seconds(4)
    var pollInterval: Duration = .milliseconds(100)

    /// Returns `true` as soon as `isReady` holds, or `false` once the timeout elapses.
    func wait(until isReady: () -> Bool) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while true {
            try Task.checkCancellation()
            if isReady() { return true }
            guard clock.now < deadline else { return false }
            try await clock.sleep(for: pollInterval)
        }
    }
}
