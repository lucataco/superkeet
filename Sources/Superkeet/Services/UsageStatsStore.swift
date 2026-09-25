import Foundation
import os.log

private let usageStatsLog = Logger(subsystem: "com.superkeet.app", category: "UsageStatsStore")

final class UsageStatsStore: ObservableObject, @unchecked Sendable {
    static let shared = UsageStatsStore()

    private static let assumedTypingWPM = 40.0

    struct DayBucket: Codable {
        var words: Int
        var seconds: Double
        var sessions: Int

        init(words: Int, seconds: Double, sessions: Int) {
            self.words = words
            self.seconds = seconds
            self.sessions = sessions
        }

        /// Missing counters read as zero so a file from another version still loads.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            words = try container.decodeIfPresent(Int.self, forKey: .words) ?? 0
            seconds = try container.decodeIfPresent(Double.self, forKey: .seconds) ?? 0
            sessions = try container.decodeIfPresent(Int.self, forKey: .sessions) ?? 0
        }
    }

    @Published private(set) var buckets: [String: DayBucket] = [:]
    @Published private(set) var persistenceIssue: String?
    @Published private(set) var recoveryBackupURL: URL?

    private let fileURL: URL
    private let storeFile: RecoverableStoreFile
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private lazy var persistence = DebouncedStoreWriter<[String: DayBucket]>(
        queueLabel: "com.superkeet.usage-stats-store",
        write: { [storeFile, encoder] in try storeFile.write(encoder.encode($0)) },
        didSave: { [weak self] in self?.completeSave($0) }
    )

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
            ?? AppPaths.applicationSupportDirectory.appendingPathComponent("usage-stats.json")
        self.storeFile = RecoverableStoreFile(url: self.fileURL)
        load()
    }

    func record(wordCount: Int, durationSeconds: Double) {
        record(wordCount: wordCount, durationSeconds: durationSeconds, on: Date())
    }

    func record(wordCount: Int, durationSeconds: Double, on date: Date) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard wordCount > 0 || durationSeconds > 0 else { return }
        let key = Self.dayFormatter.string(from: date)
        var bucket = buckets[key] ?? DayBucket(words: 0, seconds: 0, sessions: 0)
        bucket.words += wordCount
        bucket.seconds += durationSeconds
        bucket.sessions += 1
        buckets[key] = bucket
        save()
    }

    func reset() {
        dispatchPrecondition(condition: .onQueue(.main))
        buckets = [:]
        save()
    }

    func flushPendingSave() {
        dispatchPrecondition(condition: .onQueue(.main))
        persistence.flush(buckets)
    }

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

    var averageWordsPerMinute: Double {
        let minutes = totalSeconds / 60.0
        guard minutes > 0 else { return 0 }
        return Double(totalWords) / minutes
    }

    var timeSavedMinutes: Double {
        let typingMinutes = Double(totalWords) / Self.assumedTypingWPM
        let speakingMinutes = totalSeconds / 60.0
        return max(0, typingMinutes - speakingMinutes)
    }

    var currentStreak: Int {
        Self.currentStreak(in: buckets, calendar: Self.dayFormatter.calendar, now: Date())
    }

    static func currentStreak(in buckets: [String: DayBucket], calendar: Calendar, now: Date) -> Int {
        let activeDays = Set(buckets.keys)
        guard !activeDays.isEmpty else { return 0 }

        var date = calendar.startOfDay(for: now)
        let todayKey = Self.dayFormatter.string(from: date)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: date)
        let yesterdayKey = yesterday.map { Self.dayFormatter.string(from: $0) }
        if !activeDays.contains(todayKey), let yesterdayKey, activeDays.contains(yesterdayKey), let yesterday {
            date = yesterday
        }

        var streak = 0
        while activeDays.contains(Self.dayFormatter.string(from: date)) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: date) else { break }
            date = previous
        }
        return streak
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let (loaded, dropped) = try LossyDecoding.dictionary(DayBucket.self, from: data, decoder: decoder)
            buckets = loaded
            if dropped > 0 {
                storeFile.needsRecoveryBackup = true
                persistenceIssue = "\(dropped) days of usage statistics could not be read. The original file will be preserved before any new statistics are saved."
                usageStatsLog.error("Skipped \(dropped) unreadable usage-stat days")
            }
        } catch {
            storeFile.needsRecoveryBackup = true
            persistenceIssue = "Could not load usage statistics. The original file will be preserved before any new statistics are saved. \(error.localizedDescription)"
            usageStatsLog.error("Failed to load stats: \(error.localizedDescription)")
        }
    }

    private func save() {
        persistence.schedule(buckets)
    }

    private func completeSave(_ result: Result<URL?, Error>) {
        dispatchPrecondition(condition: .onQueue(.main))
        switch result {
        case .success(let backup):
            recoveryBackupURL = backup
            persistenceIssue = backup.map { "Earlier statistics could not be loaded. Their original file is preserved at \($0.path)." }
        case .failure(let error):
            usageStatsLog.error("Failed to save stats: \(error.localizedDescription)")
            persistenceIssue = "Could not save usage statistics: \(error.localizedDescription)"
        }
    }
}
