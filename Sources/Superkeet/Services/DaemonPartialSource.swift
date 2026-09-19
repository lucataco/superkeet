import Foundation

@MainActor
protocol InterimTranscriptProviding: AnyObject {
    var daemonStreamsInterimText: Bool { get }
    var daemonProtocolVersion: Int? { get }
    func interimTranscripts(sessionID: String) -> AsyncStream<PartialTranscript>
    func endInterimTranscripts(sessionID: String)
}

extension ParakeetService: InterimTranscriptProviding {}

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

    func installAssets() async throws {}

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
