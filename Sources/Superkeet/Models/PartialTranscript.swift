import AVFoundation
import Foundation

/// The running text of an utterance while the user is still speaking. Each
/// value replaces the previous one for the same session; `sequence` increases
/// monotonically so a late consumer can discard out-of-order values.
struct PartialTranscript: Equatable, Sendable {
    let text: String
    /// Whether the recogniser has committed every word in `text`. Only the
    /// final transcript from the speech engine is authoritative; a partial
    /// marked final is still just a strong hint.
    let isFinal: Bool
    let sequence: Int
}

/// One phrase from a streaming recogniser, covering `start..<end` seconds of
/// the session's audio. Volatile phrases for a range are replaced by later
/// phrases for that range until a final phrase commits it.
struct RecognizedPhrase: Equatable, Sendable {
    let text: String
    let isFinal: Bool
    let start: Double
    let end: Double
}

/// Whether interim speech text can be produced on this system right now.
enum PartialTranscriptAvailability: Equatable, Sendable {
    case available
    case requiresNewerOS
    case unsupportedLocale(String)
    case assetsNotInstalled
    case assetsDownloading
    case unavailable(String)

    var isAvailable: Bool { self == .available }

    var userFacingMessage: String? {
        switch self {
        case .available:
            return nil
        case .requiresNewerOS:
            return "Live command recognition needs macOS 26 or later."
        case .unsupportedLocale(let locale):
            return "Live command recognition does not support the \(locale) locale."
        case .assetsNotInstalled:
            return "Live command recognition needs the on-device speech model. Superkeet can download it."
        case .assetsDownloading:
            return "The on-device speech model is still downloading."
        case .unavailable(let detail):
            return "Live command recognition is unavailable: \(detail)"
        }
    }
}

/// Produces interim text for a recording session. Implementations subscribe to
/// the shared microphone tap and stream `PartialTranscript` values until
/// `stop()` is called or the session's audio ends. Exactly one session runs at
/// a time; starting a new one stops the previous one.
@MainActor
protocol PartialTranscriptSource: AnyObject {
    /// Short user-facing name of the recogniser behind this source.
    var displayName: String { get }
    func availability() async -> PartialTranscriptAvailability
    /// Downloads the on-device speech model when `availability()` reports
    /// `.assetsNotInstalled`. Only call after the user has asked for it.
    func installAssets() async throws
    /// Loads recogniser resources ahead of time so the first result of the next
    /// session arrives sooner. Safe to call repeatedly; failures are logged, not thrown.
    func prewarm() async
    func start(sessionID: String) async throws -> AsyncStream<PartialTranscript>
    func stop()
}

/// Streaming recogniser behind `SpeechAnalyzerPartialSource`. The real engine
/// wraps `SpeechAnalyzer`; tests substitute a fake that emits phrases on demand.
/// `append` is called on the audio tap's thread and must not block.
protocol StreamingSpeechRecognizing: AnyObject, Sendable {
    func availability() async -> PartialTranscriptAvailability
    func installAssets() async throws
    func prewarm() async
    /// Starts a recognition session. Phrases arrive on the returned stream
    /// until `finish()` is called or the recogniser fails.
    func start() async throws -> AsyncThrowingStream<RecognizedPhrase, Error>
    func append(_ buffer: AVAudioPCMBuffer)
    func finish() async
}

/// Merges streamed phrases into the running text of an utterance. Final
/// phrases are kept in order; the newest volatile phrase supplies the
/// uncommitted tail. A final phrase supersedes any volatile phrase that began
/// before the final phrase ended.
struct PartialTranscriptAssembler: Sendable {
    private var finalized: [RecognizedPhrase] = []
    private var volatile: RecognizedPhrase?
    private(set) var sequence = 0

    /// Applies a phrase and returns the updated transcript, or `nil` when the
    /// phrase changes nothing a consumer would notice.
    mutating func apply(_ phrase: RecognizedPhrase) -> PartialTranscript? {
        guard !phrase.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let previous = snapshot
        if phrase.isFinal {
            if let index = finalized.firstIndex(where: { $0.start >= phrase.end }) {
                finalized.insert(phrase, at: index)
            } else {
                finalized.append(phrase)
            }
            if let volatile, volatile.start < phrase.end { self.volatile = nil }
        } else {
            // A volatile phrase that ends inside already-committed audio is stale.
            guard finalized.last.map({ phrase.end > $0.end }) ?? true else { return nil }
            volatile = phrase
        }
        let current = snapshot
        guard current != previous else { return nil }
        sequence += 1
        return PartialTranscript(text: current.text, isFinal: current.isFinal, sequence: sequence)
    }

    var transcript: String { snapshot.text }

    private var snapshot: (text: String, isFinal: Bool) {
        let parts = finalized.map(\.text) + [volatile?.text].compactMap { $0 }
        let text = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return (text, volatile == nil)
    }

    mutating func reset() {
        finalized.removeAll()
        volatile = nil
        sequence = 0
    }
}
