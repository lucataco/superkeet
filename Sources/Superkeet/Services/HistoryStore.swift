import Foundation

/// Persists transcription history to a JSON file on disk
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published var records: [TranscriptionRecord] = []

    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let superkeetDir = appSupport.appendingPathComponent("Superkeet", isDirectory: true)
        try? FileManager.default.createDirectory(at: superkeetDir, withIntermediateDirectories: true)
        self.fileURL = superkeetDir.appendingPathComponent("history.json")

        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        decoder.dateDecodingStrategy = .iso8601

        loadRecords()
    }

    // MARK: - CRUD

    func addRecord(_ record: TranscriptionRecord) {
        guard AppSettings.shared.saveHistoryEnabled else { return }
        records.insert(record, at: 0)
        saveRecords()
    }

    func deleteRecord(_ record: TranscriptionRecord) {
        records.removeAll { $0.id == record.id }
        saveRecords()
    }

    func clearHistory() {
        records.removeAll()
        saveRecords()
    }

    // MARK: - Stats

    /// Records from the current calendar week (Monday-Sunday)
    var recordsThisWeek: [TranscriptionRecord] {
        let calendar = Calendar.current
        let now = Date()
        guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start else {
            return []
        }
        return records.filter { $0.timestamp >= weekStart }
    }

    var wordsTranscribedThisWeek: Int {
        recordsThisWeek.reduce(0) { $0 + $1.wordCount }
    }

    var averageWordsPerMinute: Double {
        let relevant = records.filter { $0.durationSeconds > 0 }
        guard !relevant.isEmpty else { return 0 }
        let totalWords = relevant.reduce(0) { $0 + $1.wordCount }
        let totalMinutes = relevant.reduce(0.0) { $0 + $1.durationSeconds / 60.0 }
        guard totalMinutes > 0 else { return 0 }
        return Double(totalWords) / totalMinutes
    }

    var uniqueAppsUsedThisWeek: Int {
        Set(recordsThisWeek.map { $0.activeAppBundleId }).filter { !$0.isEmpty }.count
    }

    /// Estimated time saved in minutes (assuming average typing speed of 40 WPM)
    var timeSavedThisWeekMinutes: Double {
        let words = wordsTranscribedThisWeek
        let typingTime = Double(words) / 40.0  // minutes to type at 40 WPM
        let speakingTime = recordsThisWeek.reduce(0.0) { $0 + $1.durationSeconds / 60.0 }
        return max(0, typingTime - speakingTime)
    }

    // MARK: - Persistence

    private func loadRecords() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            records = try decoder.decode([TranscriptionRecord].self, from: data)
        } catch {
            print("[HistoryStore] Failed to load history: \(error)")
        }
    }

    private func saveRecords() {
        do {
            let data = try encoder.encode(records)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[HistoryStore] Failed to save history: \(error)")
        }
    }
}
