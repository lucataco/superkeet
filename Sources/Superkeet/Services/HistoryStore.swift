import Foundation
import os.log

private let historyLog = Logger(subsystem: "com.superkeet.app", category: "HistoryStore")

final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    private static let maxRecords = 1000

    @Published var records: [TranscriptionRecord] = []
    @Published private(set) var persistenceIssue: String?
    @Published private(set) var recoveryBackupURL: URL?

    private let fileURL: URL
    private let storeFile: RecoverableStoreFile
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private lazy var persistence = DebouncedStoreWriter<[TranscriptionRecord]>(
        queueLabel: "com.superkeet.history-store",
        write: { [storeFile, encoder] in try storeFile.write(encoder.encode($0)) },
        didSave: { [weak self] in self?.completeSave($0) }
    )

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
            ?? AppPaths.applicationSupportDirectory.appendingPathComponent("history.json")
        self.storeFile = RecoverableStoreFile(url: self.fileURL)

        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        decoder.dateDecodingStrategy = .iso8601

        loadRecords()
    }

    func addRecord(_ record: TranscriptionRecord) {
        dispatchPrecondition(condition: .onQueue(.main))
        records.insert(record, at: 0)
        if records.count > Self.maxRecords {
            records = Array(records.prefix(Self.maxRecords))
        }
        saveRecords()
    }

    func deleteRecord(_ record: TranscriptionRecord) {
        dispatchPrecondition(condition: .onQueue(.main))
        records.removeAll { $0.id == record.id }
        saveRecords()
    }

    func clearHistory() {
        dispatchPrecondition(condition: .onQueue(.main))
        records.removeAll()
        saveRecords()
    }

    func flushPendingSave() {
        dispatchPrecondition(condition: .onQueue(.main))
        persistence.flush(records)
    }

    private func loadRecords() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            records = try decoder.decode([TranscriptionRecord].self, from: data)
            if records.count > Self.maxRecords {
                records = Array(records.prefix(Self.maxRecords))
                saveRecords()
            }
        } catch {
            storeFile.needsRecoveryBackup = true
            persistenceIssue = "Could not load history. The original file will be preserved before any new history is saved. \(error.localizedDescription)"
            historyLog.error("Failed to load history: \(error.localizedDescription)")
        }
    }

    private func saveRecords() {
        persistence.schedule(records)
    }

    private func completeSave(_ result: Result<URL?, Error>) {
        dispatchPrecondition(condition: .onQueue(.main))
        switch result {
        case .success(let backup):
            recoveryBackupURL = backup
            persistenceIssue = backup.map { "Earlier history could not be loaded. Its original file is preserved at \($0.path)." }
        case .failure(let error):
            historyLog.error("Failed to save history: \(error.localizedDescription)")
            persistenceIssue = "Could not save history: \(error.localizedDescription)"
        }
    }
}
