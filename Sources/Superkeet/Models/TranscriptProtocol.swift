import Foundation

struct TranscriptEvent: Codable, Equatable {
    let type: String
    let sessionID: String
    var text: String?
    var status: String?
    var failedSegments: Int?
    var droppedSamples: Int?
    var message: String?
    var sequence: Int?
    var truncated: Bool?
    var audioMS: Int?
    var trailingSilenceMS: Int?
    var decodedMS: Int?

    enum CodingKeys: String, CodingKey {
        case type, text, status, message, sequence, truncated
        case sessionID = "session_id"
        case failedSegments = "failed_segments"
        case droppedSamples = "dropped_samples"
        case audioMS = "audio_ms"
        case trailingSilenceMS = "trailing_silence_ms"
        case decodedMS = "decoded_ms"
    }

    var isPartial: Bool {
        status == "partial" || status == "error" || (failedSegments ?? 0) > 0 || (droppedSamples ?? 0) > 0
    }

    var kind: TranscriptEventKind {
        switch type {
        case "session_started": return .sessionStarted
        case "transcribing": return .transcribing
        case "partial": return .partial
        case "tick": return .tick
        case "complete": return .complete
        default: return .unrecognized(type)
        }
    }

    var interimTranscript: PartialTranscript? {
        guard kind == .partial, let text, let sequence, sequence > 0 else { return nil }
        let audio = audioMS.flatMap { $0 >= 0 ? Duration.milliseconds($0) : nil }
        return PartialTranscript(text: text, isFinal: false, sequence: sequence, audio: audio)
    }

    var tick: EngineTick? {
        guard kind == .tick, let audioMS, let trailingSilenceMS, audioMS >= 0, trailingSilenceMS >= 0 else { return nil }
        return EngineTick(
            sessionID: sessionID, audio: .milliseconds(audioMS), trailingSilence: .milliseconds(trailingSilenceMS),
            decoded: decodedMS.flatMap { $0 >= 0 ? Duration.milliseconds($0) : nil }
        )
    }
}

/// Sent on every preview tick of a take that streams partials, about every 0.5 s of audio,
/// whether or not the text changed. `trailingSilence` is how much of the end of the audio the
/// engine's voice-activity detector heard as silence; before any speech it is all of it.
///
/// parakeet-cli 0.1.13 also sends one when a pause reaches 128 ms and then every 64 ms of that
/// pause up to 1.6 s, and adds `decoded`: how much of the audio the newest finished interim
/// decode had heard. Older engines send neither.
struct EngineTick: Equatable, Sendable {
    let sessionID: String
    let audio: Duration
    let trailingSilence: Duration
    let decoded: Duration?

    /// The end of speech is rounded up to a 32 ms chunk, so a decode that heard the last word
    /// can report up to two chunks less than `audio - trailingSilence`.
    static let decodedSlack: Duration = .milliseconds(64)

    init(sessionID: String, audio: Duration, trailingSilence: Duration, decoded: Duration? = nil) {
        self.sessionID = sessionID
        self.audio = audio
        self.trailingSilence = trailingSilence
        self.decoded = decoded
    }

    /// Whether the interim text has heard everything said before this silence. A pause is
    /// reported the moment it happens, which can be before the words that ended in it are
    /// decoded; acting then would act on a sentence missing its last words. An engine that does
    /// not say what it has decoded is taken at its word, as before.
    var textIsCurrent: Bool {
        guard let decoded else { return true }
        return decoded + Self.decodedSlack >= speechEnd
    }

    /// Where in the take's audio the silence began.
    var speechEnd: Duration { audio - trailingSilence }
}

enum TranscriptEventKind: Equatable {
    case sessionStarted
    case transcribing
    case partial
    case tick
    case complete
    case unrecognized(String)
}

struct TranscriptEventStream {
    var maximumMessageBytes = 8 * 1_024 * 1_024
    private var pending = Data()

    init(maximumMessageBytes: Int = 8 * 1_024 * 1_024) {
        self.maximumMessageBytes = maximumMessageBytes
    }

    mutating func append(_ data: Data) throws -> [TranscriptEvent] {
        var events: [TranscriptEvent] = []
        for slice in data.split(separator: 0x0A, omittingEmptySubsequences: false).enumerated() {
            if slice.offset > 0 {
                if !pending.isEmpty {
                    do {
                        events.append(try JSONDecoder().decode(TranscriptEvent.self, from: pending))
                    } catch {
                        throw TranscriptProtocolError.invalidMessage
                    }
                }
                pending.removeAll(keepingCapacity: true)
            }
            guard slice.element.count <= maximumMessageBytes - pending.count else {
                pending.removeAll()
                throw TranscriptProtocolError.messageTooLarge
            }
            pending.append(contentsOf: slice.element)
        }
        return events
    }

    func finish() throws {
        guard pending.isEmpty else { throw TranscriptProtocolError.incompleteMessage }
    }
}

enum TranscriptProtocolError: LocalizedError {
    case invalidMessage, messageTooLarge, incompleteMessage, unsupportedEngine

    var errorDescription: String? {
        switch self {
        case .invalidMessage:
            return "Superkeet got a transcript it couldn't read. Reinstall Superkeet."
        case .messageTooLarge:
            return "The transcript exceeded the 8 MB message limit. It was not delivered because it could be incomplete."
        case .incompleteMessage:
            return "The transcript was cut off. Try again."
        case .unsupportedEngine:
            return "Part of Superkeet is out of date. Reinstall Superkeet."
        }
    }
}
