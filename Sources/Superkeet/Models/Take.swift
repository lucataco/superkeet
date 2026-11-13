import Foundation

/// One recording, from the moment it is asked for until its text is delivered or it is cancelled.
/// What kind of take it is and how it was started are fixed when it is created, so nothing said
/// or pressed later can change how its transcript is used.
struct Take: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case dictation
        case command
    }

    enum Trigger: Equatable, Sendable {
        case toggle
        case pushToTalk
    }

    enum Phase: Equatable, Sendable {
        /// Asked for; microphone access and the engine are still being made ready.
        case requested
        /// `start` was sent to the engine and its answer has not arrived.
        case starting
        case recording
        case transcribing
        /// The user cancelled; the engine is still letting go of the session.
        case cancelling
    }

    let id: UUID
    let kind: Kind
    let trigger: Trigger
    private(set) var phase: Phase = .requested

    init(id: UUID = UUID(), kind: Kind, trigger: Trigger) {
        self.id = id
        self.kind = kind
        self.trigger = trigger
    }

    /// The name the engine knows this take by.
    var sessionID: String { id.uuidString }

    /// Asked for, but the microphone is not open yet.
    var isPending: Bool { phase == .requested || phase == .starting }

    /// Still open to the user: the shortcut that started it stops or cancels it.
    var isOpen: Bool { isPending || phase == .recording }

    /// The engine session whose output belongs to this take, if it has one.
    var liveSessionID: String? {
        switch phase {
        case .starting, .recording, .transcribing: return sessionID
        case .requested, .cancelling: return nil
        }
    }

    func accepts(_ event: TranscriptEvent) -> Bool {
        liveSessionID == event.sessionID
    }

    /// Moves to `next` if a take can go there from where it is. Returns whether it moved.
    @discardableResult
    mutating func advance(to next: Phase) -> Bool {
        guard Self.allows(from: phase, to: next) else { return false }
        phase = next
        return true
    }

    static func allows(from current: Phase, to next: Phase) -> Bool {
        switch (current, next) {
        case (.requested, .starting),
             (.starting, .recording),
             (.starting, .transcribing),
             (.recording, .transcribing),
             (.starting, .cancelling),
             (.recording, .cancelling),
             (.transcribing, .cancelling):
            return true
        default:
            return false
        }
    }
}

enum TakeStartResult: Equatable, Sendable {
    case started
    /// The engine would not start it; the take is over and nothing has told the user yet.
    case failed
    /// The take was cancelled or ended while the engine was answering; whoever ended it has
    /// already said so.
    case superseded
}
