import Foundation

struct TranscriptEvent: Codable, Equatable {
    let type: String
    let sessionID: String
    var text: String?
    var status: String?
    var failedSegments: Int?
    var droppedSamples: Int?
    var message: String?
    /// Protocol 2 `partial` events: 1-based order within the session.
    var sequence: Int?
    /// Protocol 2 `partial` events: the preview window left out older audio.
    var truncated: Bool?

    enum CodingKeys: String, CodingKey {
        case type, text, status, message, sequence, truncated
        case sessionID = "session_id"
        case failedSegments = "failed_segments"
        case droppedSamples = "dropped_samples"
    }

    /// Whether a `complete` event reports loss or failure. Unrelated to the
    /// protocol-2 `partial` event type, which is interim text.
    var isPartial: Bool {
        status == "partial" || status == "error" || (failedSegments ?? 0) > 0 || (droppedSamples ?? 0) > 0
    }

    var kind: TranscriptEventKind {
        switch type {
        case "session_started": return .sessionStarted
        case "transcribing": return .transcribing
        case "partial": return .partial
        case "complete": return .complete
        default: return .unrecognized(type)
        }
    }

    /// The interim transcript a protocol-2 `partial` event carries, or `nil`
    /// for any other event or a malformed one.
    var interimTranscript: PartialTranscript? {
        guard kind == .partial, let text, let sequence, sequence > 0 else { return nil }
        return PartialTranscript(text: text, isFinal: false, sequence: sequence)
    }
}

/// Event types the client understands, plus a bucket for anything newer. The
/// client ignores event types it does not know instead of failing the session,
/// so an engine upgrade never has to be lock-stepped with the app.
enum TranscriptEventKind: Equatable {
    case sessionStarted
    case transcribing
    /// Protocol 2: interim text while the session still records. Advisory; only
    /// `complete` carries the transcript.
    case partial
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
    case invalidMessage, messageTooLarge, incompleteMessage

    var errorDescription: String? {
        switch self {
        case .invalidMessage:
            return "The speech engine sent an invalid transcript message. Rebuild or reinstall the compatible speech engine."
        case .messageTooLarge:
            return "The transcript exceeded the 8 MB message limit. It was not delivered because it could be incomplete."
        case .incompleteMessage:
            return "The speech engine closed its output before the transcript message was complete."
        }
    }
}

struct TranscriptSessionGate {
    private(set) var sessionID: String?

    mutating func begin(_ id: String) -> Bool {
        guard sessionID == nil else { return false }
        sessionID = id
        return true
    }

    func accepts(_ event: TranscriptEvent) -> Bool { event.sessionID == sessionID }

    mutating func close() { sessionID = nil }
}
