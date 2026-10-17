import Foundation

enum TranscriptOutcome: Equatable, Sendable {
    case copied
    case pasted
    case done
    case partial
    case noSpeech
    case failed
    case command
    case ignored

    var label: String {
        switch self {
        case .copied: return "Copied"
        case .pasted: return "Pasted"
        case .done: return "Done"
        case .partial: return "Partial transcript copied"
        case .noSpeech: return "No speech detected"
        case .failed: return "Transcription failed"
        case .command: return "Working on it…"
        case .ignored: return "Nothing to do"
        }
    }

    var symbolName: String {
        switch self {
        case .copied: return "doc.on.clipboard.fill"
        case .pasted, .done: return "checkmark.circle.fill"
        case .partial: return "exclamationmark.triangle.fill"
        case .noSpeech: return "mic.slash.fill"
        case .failed: return "xmark.octagon.fill"
        case .command: return "wand.and.stars"
        case .ignored: return "ellipsis.circle"
        }
    }

    enum Severity: Equatable, Sendable {
        case success, neutral, warning, failure
    }

    var severity: Severity {
        switch self {
        case .copied, .pasted: return .success
        case .done, .noSpeech, .command, .ignored: return .neutral
        case .partial: return .warning
        case .failed: return .failure
        }
    }

    var displayDuration: TimeInterval {
        switch severity {
        case .success: return 0.9
        case .neutral: return 1.2
        case .warning, .failure: return 2.0
        }
    }

    var showsInOverlay: Bool { self != .command }

    static func forDictation(delivery: PasteDelivery, isPartial: Bool) -> TranscriptOutcome {
        if isPartial { return .partial }
        switch delivery {
        case .pasted: return .pasted
        case .copied, .pasteFailed: return .copied
        }
    }
}

struct TranscriptOutcomeEvent: Equatable, Sendable {
    let outcome: TranscriptOutcome
    let id: UUID

    init(_ outcome: TranscriptOutcome, id: UUID = UUID()) {
        self.outcome = outcome
        self.id = id
    }
}

enum OverlayPhase: Equatable, Sendable {
    case recording
    case transcribing
    case result(TranscriptOutcome)

    var isRecording: Bool { self == .recording }
}
