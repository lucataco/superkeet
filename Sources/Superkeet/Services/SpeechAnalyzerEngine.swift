import AVFoundation
import Foundation
import os

#if canImport(FoundationModels)
import Speech

private let engineLog = Logger(subsystem: "com.superkeet.app", category: "SpeechAnalyzerEngine")

@available(macOS 26.0, *)
@MainActor
final class SpeechAnalyzerEngine: StreamingSpeechRecognizing {
    struct Configuration: Sendable {
        var locale: Locale = .current
        /// App names bias recognition toward "open Notes…" style commands. Reuse the memoized
        /// inventory instead of rescanning /Applications on every start.
        var contextualStrings: @Sendable () -> [String] = {
            MainActor.assumeIsolated {
                let inventory = InstalledAppInventory.shared
                let names = inventory.installedNames()
                if names.isEmpty {
                    inventory.refresh()
                    return AppResolver().installedApplicationNames()
                }
                return names
            }
        }
        var maximumContextualStrings = 300
        var modelRetention: SpeechAnalyzer.Options.ModelRetention = .lingering
        var reportingOptions: Set<SpeechTranscriber.ReportingOption> = [.volatileResults, .fastResults]
    }

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
