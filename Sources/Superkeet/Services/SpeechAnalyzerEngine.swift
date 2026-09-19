import AVFoundation
import Foundation
import os

// `SpeechAnalyzer` is declared by the macOS 26 SDK, which is also the first SDK
// that ships FoundationModels. Gating on that import keeps older SDKs building
// with this path compiled out, exactly like the Actions Mode planner.
#if canImport(FoundationModels)
import Speech

private let engineLog = Logger(subsystem: "com.superkeet.app", category: "SpeechAnalyzerEngine")

/// On-device streaming recogniser built on Apple's `SpeechAnalyzer`. It runs
/// alongside Parakeet only to spot intents early; the final transcript always
/// comes from the speech engine. Volatile results are requested with the fast
/// preset because, measured on macOS 26/27, the first words otherwise arrive
/// only after the utterance ends.
@available(macOS 26.0, *)
@MainActor
final class SpeechAnalyzerEngine: StreamingSpeechRecognizing {
    struct Configuration: Sendable {
        var locale: Locale = .current
        /// Words the recogniser should favour, such as installed app names.
        var contextualStrings: @Sendable () -> [String] = { AppResolver().installedApplicationNames() }
        var maximumContextualStrings = 300
        var modelRetention: SpeechAnalyzer.Options.ModelRetention = .lingering
        var reportingOptions: Set<SpeechTranscriber.ReportingOption> = [.volatileResults, .fastResults]
    }

    /// State touched from the audio tap's thread.
    private struct AudioState {
        var format: AVAudioFormat?
        var converter: AVAudioConverter?
        var input: AsyncStream<AnalyzerInput>.Continuation?
        var dropped = 0
    }

    private struct Session {
        let analyzer: SpeechAnalyzer
        let transcriber: SpeechTranscriber
    }

    private let configuration: Configuration
    private let audio = OSAllocatedUnfairLock(initialState: AudioState())
    private var session: Session?

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: Availability

    /// Reports whether recognition can start. Speech assets are tracked per
    /// app, so when the system already holds the model this also reserves the
    /// locale for Superkeet (a cheap, download-free step). It never downloads.
    func availability() async -> PartialTranscriptAvailability {
        do {
            _ = try await readyTranscriber()
            return .available
        } catch let error as SpeechAnalyzerEngineError {
            if case .notAvailable(let availability) = error { return availability }
            return .unavailable(error.localizedDescription)
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    /// Downloads the locale's speech model when it is supported but absent.
    /// Call only after the user has agreed to the download.
    func installAssets() async throws {
        let locale = try await resolveLocale()
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [makeTranscriber(locale)]) else { return }
        try await request.downloadAndInstall()
    }

    func prewarm() async {
        do {
            let transcriber = try await readyTranscriber()
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
            let analyzer = SpeechAnalyzer(modules: [transcriber], options: options)
            try await analyzer.prepareToAnalyze(in: format)
            await analyzer.cancelAndFinishNow()
        } catch {
            engineLog.error("Speech prewarm failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Session

    func start() async throws -> AsyncThrowingStream<RecognizedPhrase, Error> {
        await finish()
        let transcriber = try await readyTranscriber()
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SpeechAnalyzerEngineError.noCompatibleAudioFormat
        }
        let context = AnalysisContext()
        context.contextualStrings[.general] = Array(configuration.contextualStrings().prefix(configuration.maximumContextualStrings))

        let (inputs, builder) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let analyzer = SpeechAnalyzer(inputSequence: inputs, modules: [transcriber], options: options, analysisContext: context)
        audio.withLock { $0 = AudioState(format: format, converter: nil, input: builder) }
        session = Session(analyzer: analyzer, transcriber: transcriber)

        let results = transcriber.results
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await result in results {
                        continuation.yield(RecognizedPhrase(
                            text: String(result.text.characters),
                            isFinal: result.isFinal,
                            start: result.range.start.seconds,
                            end: result.range.end.seconds
                        ))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        // Audio buffers are not Sendable, but they never leave the tap's thread here.
        audio.withLockUnchecked { state in
            guard let format = state.format, let input = state.input else { return }
            if buffer.format == format {
                input.yield(AnalyzerInput(buffer: buffer))
                return
            }
            if state.converter?.inputFormat != buffer.format {
                state.converter = AVAudioConverter(from: buffer.format, to: format)
            }
            guard let converter = state.converter,
                  let converted = Self.convert(buffer, using: converter, to: format) else {
                state.dropped += 1
                return
            }
            input.yield(AnalyzerInput(buffer: converted))
        }
    }

    func finish() async {
        let (input, dropped) = audio.withLock { state -> (AsyncStream<AnalyzerInput>.Continuation?, Int) in
            defer { state = AudioState() }
            return (state.input, state.dropped)
        }
        input?.finish()
        if dropped > 0 {
            engineLog.notice("Dropped \(dropped) microphone buffers that could not be converted")
        }
        guard let session else { return }
        self.session = nil
        await session.analyzer.cancelAndFinishNow()
    }

    // MARK: Helpers

    private var options: SpeechAnalyzer.Options {
        .init(priority: .userInitiated, modelRetention: configuration.modelRetention)
    }

    private func resolveLocale() async throws -> Locale {
        guard SpeechTranscriber.isAvailable else {
            throw SpeechAnalyzerEngineError.notAvailable(.unavailable("this Mac cannot run the on-device speech model"))
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: configuration.locale) else {
            throw SpeechAnalyzerEngineError.notAvailable(.unsupportedLocale(configuration.locale.identifier(.bcp47)))
        }
        return locale
    }

    /// A transcriber whose locale assets are installed and reserved for this app.
    private func readyTranscriber() async throws -> SpeechTranscriber {
        let locale = try await resolveLocale()
        let transcriber = makeTranscriber(locale)
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed:
            return transcriber
        case .downloading:
            throw SpeechAnalyzerEngineError.notAvailable(.assetsDownloading)
        case .unsupported:
            throw SpeechAnalyzerEngineError.notAvailable(.unsupportedLocale(locale.identifier(.bcp47)))
        case .supported:
            // A nil request means the system already has the model; asking for
            // the request reserves the locale for this app without downloading.
            guard try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) == nil else {
                throw SpeechAnalyzerEngineError.notAvailable(.assetsNotInstalled)
            }
            return transcriber
        @unknown default:
            throw SpeechAnalyzerEngineError.notAvailable(.unavailable("unknown speech asset status"))
        }
    }

    private func makeTranscriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: configuration.reportingOptions, attributeOptions: [])
    }

    /// Resamples one tap buffer into the analyzer's format. The converter keeps
    /// its resampling state between calls, so the input block must report
    /// `noDataNow` rather than `endOfStream` once the buffer has been consumed.
    nonisolated static func convert(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard conversionError == nil, status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}

#endif

enum SpeechAnalyzerEngineError: LocalizedError, Equatable {
    case notAvailable(PartialTranscriptAvailability)
    case noCompatibleAudioFormat

    var errorDescription: String? {
        switch self {
        case .notAvailable(let availability):
            return availability.userFacingMessage ?? "Live command recognition is unavailable."
        case .noCompatibleAudioFormat:
            return "The on-device speech recogniser accepted no audio format."
        }
    }
}
