import Foundation

/// Privacy-safe aggregate usage metrics.
///
/// Unlike `HistoryStore`, this store keeps **numbers only** — never transcribed
/// text — so it can run regardless of the "Save History" setting. It powers the
/// stats header (words dictated, average speaking rate, time saved).
final class UsageStatsStore: ObservableObject {
    static let shared = UsageStatsStore()

    /// Average typing speed assumed when estimating time saved (words per minute).
    private static let assumedTypingWPM = 40.0

    /// One day's worth of aggregated activity. No text is ever stored.
    struct DayBucket: Codable {
        var words: Int
        var seconds: Double
        var sessions: Int
    }

    /// Aggregates keyed by ISO `yyyy-MM-dd` (local calendar day).
    @Published private(set) var buckets: [String: DayBucket] = [:]

    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var saveDebounceTask: DispatchWorkItem?

    private let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let superkeetDir = appSupport.appendingPathComponent("Superkeet", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: superkeetDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        self.fileURL = superkeetDir.appendingPathComponent("usage-stats.json")
        load()
    }

    // MARK: - Recording

    /// Record a completed transcription. Stores only counts, never text.
    func record(wordCount: Int, durationSeconds: Double) {
        guard wordCount > 0 || durationSeconds > 0 else { return }
        let key = dayFormatter.string(from: Date())
        var bucket = buckets[key] ?? DayBucket(words: 0, seconds: 0, sessions: 0)
        bucket.words += wordCount
        bucket.seconds += durationSeconds
        bucket.sessions += 1
        buckets[key] = bucket
        save()
    }

    func reset() {
        buckets = [:]
        save()
    }

    // MARK: - Derived stats (all-time)

    var totalWords: Int {
        buckets.values.reduce(0) { $0 + $1.words }
    }

    var totalSeconds: Double {
        buckets.values.reduce(0) { $0 + $1.seconds }
    }

    var totalSessions: Int {
        buckets.values.reduce(0) { $0 + $1.sessions }
    }

    var hasData: Bool {
        totalSessions > 0
    }

    /// Average speaking rate across all recorded sessions, in words per minute.
    var averageWordsPerMinute: Double {
        let minutes = totalSeconds / 60.0
        guard minutes > 0 else { return 0 }
        return Double(totalWords) / minutes
    }

    /// Estimated minutes saved versus typing the same words at `assumedTypingWPM`.
    var timeSavedMinutes: Double {
        let typingMinutes = Double(totalWords) / Self.assumedTypingWPM
        let speakingMinutes = totalSeconds / 60.0
        return max(0, typingMinutes - speakingMinutes)
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            buckets = try decoder.decode([String: DayBucket].self, from: data)
        } catch {
            print("[UsageStatsStore] Failed to load stats: \(error)")
        }
    }

    private func save() {
        saveDebounceTask?.cancel()
        let snapshot = buckets
        let task = DispatchWorkItem { [weak self] in
            self?.performSave(snapshot)
        }
        saveDebounceTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: task)
    }

    private func performSave(_ snapshot: [String: DayBucket]) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            do {
                let data = try self.encoder.encode(snapshot)
                try data.write(to: self.fileURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.fileURL.path)
            } catch {
                print("[UsageStatsStore] Failed to save stats: \(error)")
            }
        }
    }
}
