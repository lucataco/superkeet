import Foundation
import os.log

final class PhraseReplacementStore: ObservableObject, @unchecked Sendable {
    static let shared = PhraseReplacementStore()
    @Published private(set) var rules: [PhraseReplacement] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var recoveryBackupURL: URL?
    private let fileURL: URL
    private let storeFile: RecoverableStoreFile
    private let log = Logger(subsystem: "com.superkeet.app", category: "PhraseReplacementStore")

    init(fileURL: URL = AppPaths.applicationSupportDirectory.appendingPathComponent("phrase-replacements.json")) {
        self.fileURL = fileURL
        self.storeFile = RecoverableStoreFile(url: fileURL)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            rules = try JSONDecoder().decode([PhraseReplacement].self, from: Data(contentsOf: fileURL))
        } catch {
            // Never let the next save silently replace a file we couldn't read: back it up first.
            storeFile.needsRecoveryBackup = true
            errorMessage = "Could not load phrase replacements. The original file will be preserved before any changes are saved. \(error.localizedDescription)"
            log.error("Failed to load phrase replacements: \(error.localizedDescription)")
        }
    }

    func save(_ updated: [PhraseReplacement]) {
        dispatchPrecondition(condition: .onQueue(.main))
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let backup = try storeFile.write(JSONEncoder().encode(updated))
            rules = updated
            recoveryBackupURL = backup
            errorMessage = backup.map { "Earlier phrase replacements could not be loaded. The original file is preserved at \($0.path)." }
        } catch {
            errorMessage = "Could not save phrase replacements: \(error.localizedDescription)"
            log.error("Failed to save phrase replacements: \(error.localizedDescription)")
        }
    }
}
