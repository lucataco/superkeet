import Foundation

struct NativeLaunchedApp: Equatable, Sendable {
    let name: String
    let bundleIdentifier: String?
    let processIdentifier: Int32
    let windowReady: Bool

    private static let windowReadyText = "Its window is on screen."
    private static let windowPendingText = "No window has appeared yet."

    var summary: String {
        var details = ["pid \(processIdentifier)"]
        if let bundleIdentifier, !bundleIdentifier.isEmpty { details.append(bundleIdentifier) }
        let state = windowReady ? Self.windowReadyText : Self.windowPendingText
        return "Opened \(name) (\(details.joined(separator: ", "))). \(state)"
    }

    private static let summaryPattern = try? NSRegularExpression(
        pattern: #"\AOpened (.+) \(pid (\d+)(?:, ([^)]+))?\)\. (.+)\z"#, options: .dotMatchesLineSeparators
    )

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

@MainActor
struct NativeLaunchWaiter {
    var timeout: Duration = .seconds(4)
    var pollInterval: Duration = .milliseconds(100)

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
