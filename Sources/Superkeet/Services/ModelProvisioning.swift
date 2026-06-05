import Foundation
import Combine

/// Orchestrates the one-time, on-device speech-model download.
///
/// The bundled `parakeet` binary ships inside the app, but the ~670 MB model
/// weights are downloaded on first run via `parakeet download --progress json`.
/// This service spawns that command, parses its newline-delimited JSON progress
/// stream, and publishes a `state` that the onboarding UI renders as a friendly
/// progress experience. The daemon start path also calls `ensureModelAvailable()`
/// so the model is provisioned automatically even if onboarding was skipped.
final class ModelProvisioning: ObservableObject {
    static let shared = ModelProvisioning()

    @Published private(set) var state: ModelProvisionState = .unknown

    private let settings = AppSettings.shared
    private let lock = NSLock()
    private var inFlight: Task<Void, Error>?

    /// Headroom required before we attempt the INT8 download (~670 MB on disk,
    /// plus temp files during verification).
    private static let requiredFreeBytes: Int64 = 1_500_000_000

    private init() {
        refreshInstalledState()
    }

    // MARK: - Presence

    var modelDirectoryURL: URL {
        URL(fileURLWithPath: settings.effectiveModelDirectory, isDirectory: true)
    }

    func isModelInstalled() -> Bool {
        Self.modelExists(at: modelDirectoryURL)
    }

    /// Mirrors `parakeet-cli`'s `download::model_exists`: a usable install needs
    /// an encoder + decoder pair (FP16, INT8, or legacy FP32) plus vocab + config.
    static func modelExists(at directory: URL) -> Bool {
        let fileManager = FileManager.default
        func has(_ name: String) -> Bool {
            fileManager.fileExists(atPath: directory.appendingPathComponent(name).path)
        }

        let hasFp16 = has("encoder-model.fp16.onnx") && has("decoder_joint-model.fp16.onnx")
        let hasInt8 = has("encoder-model.int8.onnx") && has("decoder_joint-model.int8.onnx")
        let hasFp32 = has("encoder-model.onnx") && has("decoder_joint-model.onnx")

        return (hasFp16 || hasInt8 || hasFp32) && has("vocab.txt") && has("config.json")
    }

    /// Reconcile published state with what's actually on disk, without
    /// disturbing an active download.
    @discardableResult
    func refreshInstalledState() -> Bool {
        let installed = isModelInstalled()
        switch state {
        case .downloading, .verifying:
            return installed
        default:
            setState(installed ? .installed : .notInstalled)
            return installed
        }
    }

    // MARK: - Provisioning

    /// Fire-and-forget entry point for UI buttons / onboarding `onAppear`.
    func startDownloadIfNeeded() {
        Task { try? await ensureModelAvailable() }
    }

    /// Force a verify/repair pass even when the model already exists. The CLI
    /// skips checksum-verified files and re-fetches only corrupted/missing ones.
    func redownload() {
        Task {
            let (task, isCreator) = claimDownloadTask()
            defer {
                if isCreator {
                    clearInFlight()
                }
            }
            try? await task.value
        }
    }

    /// Ensure the model is present, downloading it if necessary. Coalesces with
    /// any in-flight download so onboarding and daemon-start never double-fetch.
    func ensureModelAvailable() async throws {
        if isModelInstalled() {
            setState(.installed)
            return
        }

        let (task, isCreator) = claimDownloadTask()
        defer {
            if isCreator {
                clearInFlight()
            }
        }
        try await task.value
    }

    /// Synchronous critical section — keeps `NSLock` use out of async contexts.
    private func claimDownloadTask() -> (Task<Void, Error>, Bool) {
        lock.lock()
        defer { lock.unlock() }
        if let existing = inFlight {
            return (existing, false)
        }
        let created = Task { try await self.runDownload() }
        inFlight = created
        return (created, true)
    }

    private func clearInFlight() {
        lock.lock()
        defer { lock.unlock() }
        inFlight = nil
    }

    private func runDownload() async throws {
        setState(.checking)

        if let diskIssue = insufficientDiskSpaceMessage() {
            fail(diskIssue)
            throw ModelProvisioningError.message(diskIssue)
        }

        let binaryPath = settings.parakeetBinaryPath
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            let message = "Superkeet couldn't find its bundled speech engine. Reinstall the app to restore it."
            fail(message)
            throw ModelProvisioningError.message(message)
        }

        let modelDir = settings.effectiveModelDirectory
        try? FileManager.default.createDirectory(
            atPath: modelDir,
            withIntermediateDirectories: true
        )

        let outcome = try await runDownloadProcess(binaryPath: binaryPath, modelDir: modelDir)

        setState(.verifying)
        guard isModelInstalled() else {
            let detail = outcome.errorMessage
                ?? "The speech model download finished, but the files could not be verified. Please try again."
            fail(detail)
            throw ModelProvisioningError.message(detail)
        }

        setState(.installed)
    }

    // MARK: - Subprocess + NDJSON parsing

    private struct DownloadOutcome {
        let exitCode: Int32
        let errorMessage: String?
    }

    private func runDownloadProcess(binaryPath: String, modelDir: String) async throws -> DownloadOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["download", "--progress", "json", "--model-dir", modelDir]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let lineBuffer = NDJSONLineBuffer()
        let collector = DownloadCollector()

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            for line in lineBuffer.consume(data) {
                self?.handleLine(line, collector: collector)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            collector.appendStderr(data)
        }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { [weak self] proc in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                // Drain anything buffered after the last readability callback.
                let remaining = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                if !remaining.isEmpty {
                    for line in lineBuffer.consume(remaining) {
                        self?.handleLine(line, collector: collector)
                    }
                }

                let exitCode = proc.terminationStatus
                let message: String?
                if let reported = collector.errorMessage {
                    message = reported
                } else if exitCode != 0 {
                    message = collector.stderrExcerpt()
                        ?? "The speech model download failed (exit code \(exitCode))."
                } else {
                    message = nil
                }

                continuation.resume(returning: DownloadOutcome(exitCode: exitCode, errorMessage: message))
            }

            do {
                try process.run()
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    private func handleLine(_ line: Data, collector: DownloadCollector) {
        guard !line.isEmpty,
              let event = try? JSONDecoder().decode(DownloadEvent.self, from: line) else {
            return
        }

        switch event.type {
        case "start":
            let total = event.totalFiles ?? 4
            updateProgress { progress in
                progress = ModelDownloadProgress(totalFiles: total)
            }
        case "fileStart":
            updateProgress { progress in
                progress.fileIndex = event.index ?? progress.fileIndex
                progress.totalFiles = event.totalFiles ?? progress.totalFiles
                progress.currentFileName = Self.displayName(for: event.file)
                progress.downloadedBytes = 0
                progress.totalBytes = event.total ?? 0
                progress.currentFileFraction = 0
            }
        case "fileProgress":
            updateProgress { progress in
                progress.fileIndex = event.index ?? progress.fileIndex
                progress.downloadedBytes = event.downloaded ?? progress.downloadedBytes
                progress.totalBytes = event.total ?? progress.totalBytes
                progress.currentFileFraction = progress.totalBytes > 0
                    ? Double(progress.downloadedBytes) / Double(progress.totalBytes)
                    : 0
            }
        case "fileComplete":
            updateProgress { progress in
                let index = event.index ?? progress.fileIndex
                progress.completedFiles = max(progress.completedFiles, index + 1)
                progress.currentFileFraction = 0
                if event.status == "skipped" {
                    progress.currentFileName = Self.displayName(for: event.file)
                }
            }
        case "error":
            if let message = event.message {
                collector.errorMessage = message
            }
        case "complete":
            break
        default:
            break
        }
    }

    // MARK: - State helpers

    private func updateProgress(_ mutate: @escaping (inout ModelDownloadProgress) -> Void) {
        let apply = {
            var progress: ModelDownloadProgress
            if case .downloading(let current) = self.state {
                progress = current
            } else {
                progress = ModelDownloadProgress()
            }
            mutate(&progress)
            progress.recomputeOverall()
            self.state = .downloading(progress)
        }

        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    private func fail(_ message: String) {
        setState(.failed(message))
    }

    private func setState(_ newState: ModelProvisionState) {
        if Thread.isMainThread {
            state = newState
        } else {
            DispatchQueue.main.async { self.state = newState }
        }
    }

    private func insufficientDiskSpaceMessage() -> String? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey]
        let probeURL = FileManager.default.fileExists(atPath: modelDirectoryURL.path)
            ? modelDirectoryURL
            : URL(fileURLWithPath: NSHomeDirectory())

        guard let values = try? probeURL.resourceValues(forKeys: keys),
              let available = values.volumeAvailableCapacityForImportantUsage else {
            return nil  // Can't determine — let the download try.
        }

        if available < Self.requiredFreeBytes {
            let neededGB = Double(Self.requiredFreeBytes) / 1_000_000_000
            return String(
                format: "Not enough free disk space to download the speech model (need about %.1f GB free).",
                neededGB
            )
        }
        return nil
    }

    static func displayName(for file: String?) -> String {
        guard let file else { return "model files" }
        if file.contains("encoder") { return "speech encoder" }
        if file.contains("decoder") { return "decoder" }
        if file.contains("vocab") { return "vocabulary" }
        if file.contains("config") { return "configuration" }
        return file
    }
}

// MARK: - State model

struct ModelDownloadProgress: Equatable {
    var fileIndex: Int = 0
    var totalFiles: Int = 4
    var completedFiles: Int = 0
    var currentFileName: String = "model files"
    var downloadedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var currentFileFraction: Double = 0
    var overallFraction: Double = 0

    mutating func recomputeOverall() {
        guard totalFiles > 0 else {
            overallFraction = 0
            return
        }
        let fraction = (Double(completedFiles) + min(max(currentFileFraction, 0), 1)) / Double(totalFiles)
        overallFraction = min(max(fraction, 0), 1)
    }
}

enum ModelProvisionState: Equatable {
    case unknown
    case checking
    case notInstalled
    case downloading(ModelDownloadProgress)
    case verifying
    case installed
    case failed(String)

    var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }

    var isBusy: Bool {
        switch self {
        case .checking, .downloading, .verifying:
            return true
        default:
            return false
        }
    }
}

enum ModelProvisioningError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text):
            return text
        }
    }
}

// MARK: - NDJSON decoding

private struct DownloadEvent: Decodable {
    let type: String
    let file: String?
    let index: Int?
    let totalFiles: Int?
    let total: Int64?
    let downloaded: Int64?
    let status: String?
    let message: String?
    let variant: String?
    let modelDir: String?
}

/// Accumulates raw stdout bytes and splits them into complete NDJSON lines.
private final class NDJSONLineBuffer {
    private var buffer = Data()
    private let lock = NSLock()

    func consume(_ data: Data) -> [Data] {
        lock.lock()
        defer { lock.unlock() }

        buffer.append(data)
        var lines: [Data] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newlineIndex)
            lines.append(line)
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
        }
        return lines
    }
}

/// Thread-safe sink for the error message and stderr captured during a download.
private final class DownloadCollector {
    private let lock = NSLock()
    private var _errorMessage: String?
    private var stderrData = Data()

    var errorMessage: String? {
        get { lock.lock(); defer { lock.unlock() }; return _errorMessage }
        set { lock.lock(); _errorMessage = newValue; lock.unlock() }
    }

    func appendStderr(_ data: Data) {
        lock.lock()
        stderrData.append(data)
        // Keep only the tail so a chatty engine can't grow this unbounded.
        if stderrData.count > 8_192 {
            stderrData.removeSubrange(stderrData.startIndex..<(stderrData.endIndex - 8_192))
        }
        lock.unlock()
    }

    func stderrExcerpt() -> String? {
        lock.lock()
        defer { lock.unlock() }
        let text = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }
}
