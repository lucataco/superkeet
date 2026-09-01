import Foundation

enum OverlayElapsedClock {
    static func elapsed(now: Date, start: Date, isRecording: Bool) -> TimeInterval {
        guard isRecording else { return 0 }
        return max(0, now.timeIntervalSince(start))
    }

    static func formatted(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
