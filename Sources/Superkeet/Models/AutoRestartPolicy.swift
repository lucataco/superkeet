import Foundation

struct AutoRestartPolicy {
    let maxAttempts: Int
    let window: TimeInterval
    let baseDelay: TimeInterval
    let maxDelay: TimeInterval

    private(set) var attemptTimestamps: [Date] = []

    init(
        maxAttempts: Int = 3,
        window: TimeInterval = 60,
        baseDelay: TimeInterval = 2,
        maxDelay: TimeInterval = 30
    ) {
        self.maxAttempts = maxAttempts
        self.window = window
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    mutating func nextDelay(now: Date = Date()) -> TimeInterval? {
        attemptTimestamps = attemptTimestamps.filter { now.timeIntervalSince($0) < window }
        guard attemptTimestamps.count < maxAttempts else { return nil }

        let delay = min(maxDelay, baseDelay * pow(2, Double(attemptTimestamps.count)))
        attemptTimestamps.append(now)
        return delay
    }

    mutating func reset() {
        attemptTimestamps.removeAll()
    }
}
