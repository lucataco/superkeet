import Foundation

/// The user-visible result of a finished dictation take. Drives the confirmation flash in the
/// recording overlay so the user never has to guess whether their text actually landed.
enum TranscriptOutcome: Equatable, Sendable {
    case copied
    case pasted
    case done
    case partial
    case noSpeech
    case failed
    case command
    /// A command-mode take that was only a reaction ("Great, thanks."); nothing ran.
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

    /// How long the overlay lingers on this result. Successes get out of the way quickly;
    /// anything the user might need to act on stays a bit longer.
    var displayDuration: TimeInterval {
        switch severity {
        case .success: return 0.9
        case .neutral: return 1.2
        case .warning, .failure: return 2.0
        }
    }

    /// Command takes hand off to the Actions HUD, which has its own progress UI.
    var showsInOverlay: Bool { self != .command }

    /// Maps the paste service's report to the outcome shown to the user.
    static func forDictation(delivery: PasteDelivery, isPartial: Bool) -> TranscriptOutcome {
        if isPartial { return .partial }
        switch delivery {
        case .pasted: return .pasted
        case .copied, .pasteFailed: return .copied
        }
    }
}

/// A fresh identity per completion so observers react to back-to-back identical outcomes.
struct TranscriptOutcomeEvent: Equatable, Sendable {
    let outcome: TranscriptOutcome
    let id: UUID

    init(_ outcome: TranscriptOutcome, id: UUID = UUID()) {
        self.outcome = outcome
        self.id = id
    }
}

/// What the recording overlay is currently showing.
enum OverlayPhase: Equatable, Sendable {
    case recording
    case transcribing
    case result(TranscriptOutcome)

    var isRecording: Bool { self == .recording }
}
