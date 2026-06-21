import Foundation

/// A single transcription record stored in history
struct TranscriptionRecord: Identifiable, Codable {
    let id: UUID
    let text: String
    let timestamp: Date
    let durationSeconds: Double
    let wordCount: Int
    let activeAppName: String
    let activeAppBundleId: String

    var wordsPerMinute: Double {
        guard durationSeconds > 0 else { return 0 }
        return Double(wordCount) / (durationSeconds / 60.0)
    }

    init(
        text: String,
        timestamp: Date = Date(),
        durationSeconds: Double,
        activeAppName: String,
        activeAppBundleId: String
    ) {
        self.id = UUID()
        self.text = text
        self.timestamp = timestamp
        self.durationSeconds = durationSeconds
        // Split on any whitespace (tabs, newlines, NBSP, runs of spaces) so
        // tabs-pasted text and multi-line transcriptions count words correctly.
        self.wordCount = text.split(whereSeparator: { $0.isWhitespace }).count
        self.activeAppName = activeAppName
        self.activeAppBundleId = activeAppBundleId
    }
}
