import Foundation
import os.log

private let historyLog = Logger(subsystem: "com.superkeet.app", category: "HistoryStore")

/// Persists transcription history to a JSON file on disk
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    private static let maxRecords = 1000

    @Published var records: [TranscriptionRecord] = []

    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let persistenceQueue = DispatchQueue(label: "com.superkeet.history-store", qos: .utility)
    private var saveDebounceTask: DispatchWorkItem?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
            ?? AppPaths.applicationSupportDirectory.appendingPathComponent("history.json")

        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        decoder.dateDecodingStrategy = .iso8601

        loadRecords()
    }

    // MARK: - CRUD

    func addRecord(_ record: TranscriptionRecord) {
        records.insert(record, at: 0)
        if records.count > Self.maxRecords {
            records = Array(records.prefix(Self.maxRecords))
        }
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

    func flushPendingSave() {
        saveDebounceTask?.cancel()
        saveDebounceTask = nil
        let snapshot = records
        persistenceQueue.sync {
            writeRecords(snapshot)
        }
    }

    // MARK: - Persistence

    private func loadRecords() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            records = try decoder.decode([TranscriptionRecord].self, from: data)
            // Prune if history exceeds the cap (e.g., limit was lowered)
            if records.count > Self.maxRecords {
                records = Array(records.prefix(Self.maxRecords))
                saveRecords()
            }
        } catch {
            historyLog.error("Failed to load history: \(error.localizedDescription)")
        }
    }

    private func saveRecords() {
        // Debounce: coalesce rapid saves (e.g., multiple transcriptions in quick succession)
        saveDebounceTask?.cancel()
        let snapshot = records
        let task = DispatchWorkItem { [weak self] in
            self?.performSave(records: snapshot)
        }
        saveDebounceTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: task)
    }

    private func performSave(records snapshot: [TranscriptionRecord]) {
        persistenceQueue.async { [weak self] in
            guard let self = self else { return }
            self.writeRecords(snapshot)
        }
    }

    private func writeRecords(_ snapshot: [TranscriptionRecord]) {
        do {
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            historyLog.error("Failed to save history: \(error.localizedDescription)")
        }
    }
}
