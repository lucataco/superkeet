import AVFoundation
import Foundation

struct PartialTranscript: Equatable, Sendable {
    let text: String
    let isFinal: Bool
    let sequence: Int
}

struct RecognizedPhrase: Equatable, Sendable {
    let text: String
    let isFinal: Bool
    let start: Double
    let end: Double
}

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

@MainActor
protocol PartialTranscriptSource: AnyObject {
    var displayName: String { get }
    func availability() async -> PartialTranscriptAvailability
    func installAssets() async throws
    func prewarm() async
    func start(sessionID: String) async throws -> AsyncStream<PartialTranscript>
    func stop()
}

protocol StreamingSpeechRecognizing: AnyObject, Sendable {
    func availability() async -> PartialTranscriptAvailability
    func installAssets() async throws
    func prewarm() async
    func start() async throws -> AsyncThrowingStream<RecognizedPhrase, Error>
    func append(_ buffer: AVAudioPCMBuffer)
    func finish() async
}

struct PartialTranscriptAssembler: Sendable {
    private var finalized: [RecognizedPhrase] = []
    private var volatile: RecognizedPhrase?
    private(set) var sequence = 0

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
