import Foundation

struct TranscriptionRecord: Identifiable, Codable {
    let id: UUID
    let text: String
    let rawText: String?
    let isPartial: Bool?
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
        activeAppBundleId: String,
        rawText: String? = nil,
        isPartial: Bool? = nil
    ) {
        self.id = UUID()
        self.text = text
        self.rawText = rawText
        self.isPartial = isPartial
        self.timestamp = timestamp
        self.durationSeconds = durationSeconds
        self.wordCount = text.split(whereSeparator: { $0.isWhitespace }).count
        self.activeAppName = activeAppName
        self.activeAppBundleId = activeAppBundleId
    }
}
