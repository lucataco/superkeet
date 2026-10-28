import Foundation

enum TakeCompletionNotice: Equatable {
    case transcribed
    case partial
    case noSpeech

    static func resolve(isPartial: Bool, processedText: String) -> TakeCompletionNotice {
        if processedText.isEmpty { return .noSpeech }
        return isPartial ? .partial : .transcribed
    }

    var statusText: String {
        switch self {
        case .transcribed: return "Transcription complete"
        case .partial: return "Part of the recording couldn't be transcribed."
        case .noSpeech: return TranscriptOutcome.noSpeech.label
        }
    }

    var settingsDetail: String? {
        self == .partial ? statusText : nil
    }
}
