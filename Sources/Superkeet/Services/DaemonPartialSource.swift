import Foundation

/// The speech engine's side of protocol-2 interim text. `ParakeetService`
/// implements it; tests substitute a fake that yields scripted transcripts.
@MainActor
protocol InterimTranscriptProviding: AnyObject {
    var daemonStreamsInterimText: Bool { get }
    var daemonProtocolVersion: Int? { get }
    func interimTranscripts(sessionID: String) -> AsyncStream<PartialTranscript>
    func endInterimTranscripts(sessionID: String)
}

extension ParakeetService: InterimTranscriptProviding {}

/// Interim text from the Parakeet daemon itself (protocol 2). One recogniser
/// produces both the interim and the final transcript, so the app name that
/// triggers an early launch is the same one the command will see, and no
/// second microphone consumer or speech model is involved.
@MainActor
final class DaemonPartialSource: PartialTranscriptSource {
    private let engine: any InterimTranscriptProviding
    private(set) var activeSessionID: String?

    init(engine: any InterimTranscriptProviding) {
        self.engine = engine
    }

    var displayName: String { "the Parakeet engine" }

    func availability() async -> PartialTranscriptAvailability {
        engine.daemonStreamsInterimText ? .available : .unavailable(Self.unavailableReason(protocolVersion: engine.daemonProtocolVersion))
    }

    /// The engine ships its own model; nothing to install.
    func installAssets() async throws {}

    /// The engine is already loaded whenever recording is possible.
    func prewarm() async {}

    func start(sessionID: String) async throws -> AsyncStream<PartialTranscript> {
        dispatchPrecondition(condition: .onQueue(.main))
        stop()
        guard engine.daemonStreamsInterimText else {
            throw SpeechAnalyzerEngineError.notAvailable(.unavailable(Self.unavailableReason(protocolVersion: engine.daemonProtocolVersion)))
        }
        activeSessionID = sessionID
        return engine.interimTranscripts(sessionID: sessionID)
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let sessionID = activeSessionID else { return }
        activeSessionID = nil
        engine.endInterimTranscripts(sessionID: sessionID)
    }

    static func unavailableReason(protocolVersion: Int?) -> String {
        guard let protocolVersion else { return "the speech engine is not running yet" }
        return "the speech engine speaks protocol \(protocolVersion), which has no interim text"
    }
}

/// Uses the engine's interim text when the running daemon offers it and falls
/// back to another recogniser otherwise. The choice is made per session, so a
/// daemon that starts (or is upgraded) after launch is picked up without a
/// restart.
@MainActor
final class PreferredPartialSource: PartialTranscriptSource {
    private let primary: any PartialTranscriptSource
    private let fallback: (any PartialTranscriptSource)?
    private(set) var active: (any PartialTranscriptSource)?

    init(primary: any PartialTranscriptSource, fallback: (any PartialTranscriptSource)?) {
        self.primary = primary
        self.fallback = fallback
    }

    var displayName: String {
        active?.displayName ?? primary.displayName
    }

    /// The recogniser the next session would use, for status displays.
    func preferredSource() async -> (any PartialTranscriptSource)? {
        if await primary.availability().isAvailable { return primary }
        if let fallback, await fallback.availability().isAvailable { return fallback }
        return nil
    }

    func availability() async -> PartialTranscriptAvailability {
        let primaryAvailability = await primary.availability()
        if primaryAvailability.isAvailable { return primaryAvailability }
        guard let fallback else { return primaryAvailability }
        return await fallback.availability()
    }

    func installAssets() async throws {
        guard await !primary.availability().isAvailable, let fallback else { return }
        try await fallback.installAssets()
    }

    func prewarm() async {
        // The engine needs no warm-up; only the fallback does, and only while it
        // is the one that would be used.
        guard await !primary.availability().isAvailable, let fallback else { return }
        await fallback.prewarm()
    }

    func start(sessionID: String) async throws -> AsyncStream<PartialTranscript> {
        dispatchPrecondition(condition: .onQueue(.main))
        stop()
        let chosen: any PartialTranscriptSource
        if await primary.availability().isAvailable {
            chosen = primary
        } else if let fallback {
            chosen = fallback
        } else {
            let availability = await primary.availability()
            throw SpeechAnalyzerEngineError.notAvailable(availability)
        }
        let stream = try await chosen.start(sessionID: sessionID)
        active = chosen
        return stream
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        active?.stop()
        active = nil
    }
}
