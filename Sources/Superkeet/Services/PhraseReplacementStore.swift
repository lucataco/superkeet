import Foundation
import os.log

final class PhraseReplacementStore: ObservableObject {
    static let shared = PhraseReplacementStore()
    @Published private(set) var rules: [PhraseReplacement] = []
    @Published private(set) var errorMessage: String?
    private let fileURL: URL
    private let log = Logger(subsystem: "com.superkeet.app", category: "PhraseReplacementStore")

    init(fileURL: URL = AppPaths.applicationSupportDirectory.appendingPathComponent("phrase-replacements.json")) {
        self.fileURL = fileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            rules = try JSONDecoder().decode([PhraseReplacement].self, from: Data(contentsOf: fileURL))
        } catch {
            errorMessage = "Could not load phrase replacements: \(error.localizedDescription)"
        }
    }

    func save(_ updated: [PhraseReplacement]) {
        dispatchPrecondition(condition: .onQueue(.main))
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(updated).write(to: fileURL, options: .atomic)
            rules = updated
            errorMessage = nil
        } catch {
            errorMessage = "Could not save phrase replacements: \(error.localizedDescription)"
            log.error("Failed to save phrase replacements: \(error.localizedDescription)")
        }
    }
}
