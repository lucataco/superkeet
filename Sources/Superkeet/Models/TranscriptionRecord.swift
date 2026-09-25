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

extension TranscriptionRecord {
    private enum CodingKeys: String, CodingKey {
        case id, text, rawText, isPartial, timestamp, durationSeconds, wordCount, activeAppName, activeAppBundleId
    }

    /// Only `text` is required. Missing fields get neutral defaults, so a record written by an
    /// older or newer version still loads instead of hiding the whole history.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let text = try container.decode(String.self, forKey: .text)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.text = text
        self.rawText = try container.decodeIfPresent(String.self, forKey: .rawText)
        self.isPartial = try container.decodeIfPresent(Bool.self, forKey: .isPartial)
        self.timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date(timeIntervalSince1970: 0)
        self.durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0
        self.wordCount = try container.decodeIfPresent(Int.self, forKey: .wordCount)
            ?? text.split(whereSeparator: { $0.isWhitespace }).count
        self.activeAppName = try container.decodeIfPresent(String.self, forKey: .activeAppName) ?? ""
        self.activeAppBundleId = try container.decodeIfPresent(String.self, forKey: .activeAppBundleId) ?? ""
    }
}
