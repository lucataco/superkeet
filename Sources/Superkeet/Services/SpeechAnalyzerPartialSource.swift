import AVFoundation
import Foundation
import os.log

private let partialLog = Logger(subsystem: "com.superkeet.app", category: "PartialTranscript")

@MainActor
final class SpeechAnalyzerPartialSource: PartialTranscriptSource {
    private let hub: MicrophoneTapHub
    private let engine: any StreamingSpeechRecognizing
    private var subscription: MicrophoneTapHub.Subscription?
    private var relay: Task<Void, Never>?
    private var finishing: Task<Void, Never>?
    private var continuation: AsyncStream<PartialTranscript>.Continuation?
    private(set) var activeSessionID: String?

    init(hub: MicrophoneTapHub = .shared, engine: any StreamingSpeechRecognizing) {
        self.hub = hub
        self.engine = engine
    }

    var displayName: String { "Apple's on-device recogniser" }

    func availability() async -> PartialTranscriptAvailability {
        await engine.availability()
    }

    func installAssets() async throws {
        try await engine.installAssets()
    }

    func prewarm() async {
        await engine.prewarm()
    }

    func start(sessionID: String) async throws -> AsyncStream<PartialTranscript> {
        dispatchPrecondition(condition: .onQueue(.main))
        stop()
        await finishing?.value
        finishing = nil

        let phrases = try await engine.start()
        if Task.isCancelled {
            await engine.finish()
            throw CancellationError()
        }

        let engine = self.engine
        let subscription: MicrophoneTapHub.Subscription
        do {
            subscription = try hub.subscribe { buffer, _ in engine.append(buffer) }
        } catch {
            await engine.finish()
            throw error
        }
        self.subscription = subscription
        activeSessionID = sessionID

        let (stream, continuation) = AsyncStream.makeStream(of: PartialTranscript.self)
        self.continuation = continuation
        relay = Task { @MainActor [weak self] in
            var assembler = PartialTranscriptAssembler()
            do {
                for try await phrase in phrases {
                    guard let self, self.activeSessionID == sessionID else { break }
                    if let transcript = assembler.apply(phrase) {
                        continuation.yield(transcript)
                    }
                }
            } catch is CancellationError {
            } catch {
                partialLog.error("Partial transcript stream failed: \(error.localizedDescription, privacy: .public)")
            }
            continuation.finish()
            if let self, self.activeSessionID == sessionID { self.stop() }
        }
        return stream
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard activeSessionID != nil else { return }
        activeSessionID = nil
        if let subscription { hub.unsubscribe(subscription) }
        subscription = nil
        relay?.cancel()
        relay = nil
        continuation?.finish()
        continuation = nil
        let engine = self.engine
        finishing = Task { await engine.finish() }
    }
}

enum PartialTranscriptSources {
    @MainActor
    static func make(hub: MicrophoneTapHub = .shared, engine: any InterimTranscriptProviding = ParakeetService.shared) -> (any PartialTranscriptSource)? {
        let daemon = DaemonPartialSource(engine: engine)
        var fallback: (any PartialTranscriptSource)?
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            fallback = SpeechAnalyzerPartialSource(hub: hub, engine: SpeechAnalyzerEngine())
        }
        #endif
        return PreferredPartialSource(primary: daemon, fallback: fallback)
    }
}
