import Foundation
import Combine
import os.log

private let downloadLog = Logger(subsystem: "com.superkeet.app", category: "ModelProvisioning")

final class ModelProvisioning: ObservableObject, @unchecked Sendable {
    static let shared = ModelProvisioning()

    @Published private(set) var state: ModelProvisionState = .unknown

    private let settings = AppSettings.shared
    private let lock = NSLock()
    private var inFlight: Task<Void, Error>?
    private let directoryOverride: URL?
    private let prepareEngineOverride: (() async throws -> String)?
    private let downloadOverride: ((String, String) async throws -> DownloadOutcome)?

    private static let requiredFreeBytes: Int64 = 1_500_000_000

    init(
        modelDirectory: URL? = nil,
        prepareEngine: (() async throws -> String)? = nil,
        download: ((String, String) async throws -> DownloadOutcome)? = nil
    ) {
        directoryOverride = modelDirectory
        prepareEngineOverride = prepareEngine
        downloadOverride = download
        refreshInstalledState()
    }

    var modelDirectoryURL: URL {
        directoryOverride ?? URL(fileURLWithPath: settings.effectiveModelDirectory, isDirectory: true)
    }

    func isModelInstalled() -> Bool {
        Self.modelExists(at: modelDirectoryURL)
    }

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

    @discardableResult
    func refreshInstalledState() -> Bool {
        let installed = isModelInstalled()
        switch state {
        case .checking, .downloading, .verifying:
            return installed
        case .failed:
            return installed
        default:
            setState(installed ? .installed : .notInstalled)
            return installed
        }
    }

    func startDownloadIfNeeded() {
        Task { try? await ensureModelAvailable() }
    }

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

    func cancelInFlightDownload() {
        lock.lock()
        let task = inFlight
        lock.unlock()
        task?.cancel()
    }

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
        do {
            try Task.checkCancellation()
            await MainActor.run { self.setState(.checking) }

            if let diskIssue = insufficientDiskSpaceMessage() {
                throw ModelProvisioningError.message(diskIssue)
            }

            let binaryPath = try await prepareEngine()
            try Task.checkCancellation()
            guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
                let message = settings.missingParakeetBinaryMessage
                throw ModelProvisioningError.message(message)
            }

            let modelDir = modelDirectoryURL.path
            try FileManager.default.createDirectory(
                atPath: modelDir,
                withIntermediateDirectories: true
            )

            let outcome: DownloadOutcome
            if let downloadOverride {
                outcome = try await downloadOverride(binaryPath, modelDir)
            } else {
                outcome = try await runDownloadProcess(binaryPath: binaryPath, modelDir: modelDir)
            }

            try Task.checkCancellation()
            guard outcome.exitCode == 0 else {
                let detail = outcome.errorMessage
                    ?? "The speech model download failed (exit code \(outcome.exitCode))."
                throw ModelProvisioningError.message(detail)
            }

            await MainActor.run { self.setState(.verifying) }
            try Task.checkCancellation()
            guard isModelInstalled() else {
                let detail = outcome.errorMessage
                    ?? "The speech model download finished, but the files could not be verified. Please try again."
                throw ModelProvisioningError.message(detail)
            }

            await MainActor.run { self.setState(.installed) }
        } catch is CancellationError {
            await MainActor.run { self.setState(self.isModelInstalled() ? .installed : .notInstalled) }
            throw CancellationError()
        } catch {
            await MainActor.run { self.fail(error.localizedDescription) }
            throw error
        }
    }

    private func prepareEngine() async throws -> String {
        if let prepareEngineOverride { return try await prepareEngineOverride() }
        if settings.canBootstrapDevelopmentParakeet {
            return try await DevelopmentParakeetBootstrap.ensureAvailable(settings: settings)
        }
        return settings.parakeetBinaryPath
    }

    struct DownloadOutcome {
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
        let watchdog = DownloadStallWatchdog()
        let cancellationState = DownloadCancellationState()

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            watchdog.recordActivity()
            for line in lineBuffer.consume(data) {
                self?.handleLine(line, collector: collector)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            watchdog.recordActivity()
            collector.appendStderr(data)
        }

        let stallTimer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        stallTimer.schedule(deadline: .now() + 5, repeating: 5)
        stallTimer.setEventHandler {
            guard watchdog.checkForStall() else { return }
            downloadLog.error("Model download stalled for \(Int(watchdog.stallTimeout))s; terminating downloader")
            cancellationState.cancel(process)
        }
        // Resume immediately: a dispatch source must never be released while suspended. Every
        // exit path below cancels it.
        stallTimer.resume()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { [weak self] proc in
                    stallTimer.cancel()
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil

                    let remaining = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    if !remaining.isEmpty {
                        for line in lineBuffer.consume(remaining) {
                            self?.handleLine(line, collector: collector)
                        }
                    }
                    if let line = lineBuffer.drainRemainder() {
                        self?.handleLine(line, collector: collector)
                    }

                    let exitCode = proc.terminationStatus
                    let message: String?
                    if watchdog.didStall {
                        message = watchdog.stallMessage
                    } else if let reported = collector.errorMessage {
                        message = reported
                    } else if exitCode != 0 {
                        message = collector.stderrExcerpt()
                            ?? "The speech model download failed (exit code \(exitCode))."
                    } else {
                        message = nil
                    }

                    // A stall kill can exit 0 on some signal paths; never report it as success.
                    let reportedExit = watchdog.didStall && exitCode == 0 ? 1 : exitCode
                    continuation.resume(returning: DownloadOutcome(exitCode: reportedExit, errorMessage: message))
                }

                do {
                    let didRun = try cancellationState.runUnlessCancelled(process)
                    if didRun {
                        watchdog.recordActivity()
                    } else {
                        stallTimer.cancel()
                        stdoutPipe.fileHandleForReading.readabilityHandler = nil
                        stderrPipe.fileHandleForReading.readabilityHandler = nil
                        continuation.resume(throwing: CancellationError())
                    }
                } catch {
                    stallTimer.cancel()
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            cancellationState.cancel(process)
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

    private func updateProgress(_ mutate: @escaping @Sendable (inout ModelDownloadProgress) -> Void) {
        let apply: @Sendable () -> Void = {
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
            return nil
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

    /// The state's case without its payload. Observe this instead of `state` when you only care
    /// about transitions; `.downloading` is republished on every progress event.
    var phase: Phase {
        switch self {
        case .unknown: return .unknown
        case .checking: return .checking
        case .notInstalled: return .notInstalled
        case .downloading: return .downloading
        case .verifying: return .verifying
        case .installed: return .installed
        case .failed: return .failed
        }
    }

    enum Phase: Equatable {
        case unknown, checking, notInstalled, downloading, verifying, installed, failed
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

private struct DownloadEvent: Decodable {
    let type: String
    let file: String?
    let index: Int?
    let totalFiles: Int?
    let total: Int64?
    let downloaded: Int64?
    let status: String?
    let message: String?
}

final class NDJSONLineBuffer: @unchecked Sendable {
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

    func drainRemainder() -> Data? {
        lock.lock()
        defer { lock.unlock() }

        guard !buffer.isEmpty else { return nil }
        let line = buffer
        buffer.removeAll(keepingCapacity: true)
        return line
    }
}

/// Detects a model download that has stopped making progress. parakeet-cli's HTTP client has no
/// read timeout, so a dead connection would otherwise leave the download (and engine start)
/// waiting forever. Any output from the downloader counts as activity.
final class DownloadStallWatchdog: @unchecked Sendable {
    static let defaultStallTimeout: TimeInterval = 90

    let stallTimeout: TimeInterval
    private let lock = NSLock()
    private var lastActivity: Date
    private var _didStall = false

    init(stallTimeout: TimeInterval = DownloadStallWatchdog.defaultStallTimeout, now: Date = Date()) {
        self.stallTimeout = stallTimeout
        self.lastActivity = now
    }

    func recordActivity(at now: Date = Date()) {
        lock.lock()
        lastActivity = now
        lock.unlock()
    }

    /// Returns true exactly once, the first time the download is seen stalled.
    func checkForStall(at now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !_didStall, now.timeIntervalSince(lastActivity) >= stallTimeout else { return false }
        _didStall = true
        return true
    }

    var didStall: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _didStall
    }

    var stallMessage: String {
        "The speech model download stopped making progress for \(Int(stallTimeout)) seconds. Check your internet connection and try again."
    }
}

final class DownloadCollector: @unchecked Sendable {
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

private final class DownloadCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var _isCancelled = false

    func runUnlessCancelled(_ process: Process) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !_isCancelled else { return false }
        try process.run()
        return true
    }

    func cancel(_ process: Process) {
        lock.lock()
        _isCancelled = true
        let shouldTerminate = process.isRunning
        lock.unlock()

        guard shouldTerminate else { return }
        process.terminate()

        // Escalate to SIGKILL if the downloader ignores SIGTERM (e.g. blocked in network I/O),
        // so cancellation — and therefore app quit — can never hang on it.
        let pid = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.killGracePeriod) {
            guard process.isRunning, process.processIdentifier == pid else { return }
            kill(pid, SIGKILL)
        }
    }

    static let killGracePeriod: TimeInterval = 2.0
}
