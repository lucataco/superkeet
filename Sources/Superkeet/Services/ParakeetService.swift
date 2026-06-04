import Foundation
import AppKit
import Darwin

/// Manages the parakeet serve daemon subprocess and communicates via Unix socket
final class ParakeetService: ObservableObject {
    static let shared = ParakeetService()
    private static let startupPollIntervalNanoseconds: UInt64 = 100_000_000
    private static let startupTimeoutNanoseconds: UInt64 = 20_000_000_000

    @Published var daemonState: DaemonState = .stopped
    @Published var lastTranscription: String = ""
    @Published var lastUserFacingError: String?
    @Published var lastDiagnosticsSummary: String?
    @Published var startupStatusDetail: String?

    enum DaemonState: String {
        case stopped
        case starting
        case idle
        case recording
        case stopping
    }

    private var daemonProcess: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private let settings = AppSettings.shared
    private var outputBuffer: String = ""
    private var stderrBuffer: String = ""
    private var recordingStartTime: Date?
    private var activeAppAtRecordingStart: (name: String, bundleId: String)?
    private var lastDeliveredTranscription: String?
    private var idleShutdownTask: DispatchWorkItem?
    private let lifecycleLock = NSLock()
    private var startTask: Task<Void, Error>?
    private var stopTask: Task<Void, Never>?
    private var autoRestartTask: Task<Void, Never>?
    private var autoRestartPolicy = AutoRestartPolicy()

    private static let maxBufferedOutputCharacters = 16_384

    private init() {}

    // MARK: - Daemon Management

    func startDaemon() async throws {
        let pendingStop = lifecycleLock.withLock { stopTask }
        if let pendingStop {
            await pendingStop.value
        }

        let (task, createdTask) = lifecycleLock.withLock { () -> (Task<Void, Error>?, Bool) in
            if let startTask {
                return (startTask, false)
            }

            if daemonProcess != nil {
                return (nil, false)
            }

            let task = Task { try await self.performStartDaemon() }
            startTask = task
            return (task, true)
        }

        guard let task else {
            return
        }

        defer {
            if createdTask {
                lifecycleLock.withLock {
                    startTask = nil
                }
            }
        }

        try await task.value
    }

    private func performStartDaemon() async throws {
        await MainActor.run {
            self.lastUserFacingError = nil
            self.lastDiagnosticsSummary = nil
            self.startupStatusDetail = "Starting daemon"
            self.settings.runtimeIssue = nil
        }
        autoRestartTask?.cancel()
        autoRestartTask = nil

        // Kill any orphaned daemon from a previous run
        await killStaleProcesses()

        try ensureRuntimeDirectory()

        let readiness = AppReadiness.current(settings: settings)
        if readiness.hasDaemonBlockingIssue {
            let detail = readiness.issues.contains(.engine)
                ? "Superkeet could not find the embedded Parakeet engine at \(settings.parakeetBinaryPath). Reinstall the app to restore the bundled engine."
                : "Superkeet could not prepare its runtime directory at \(readiness.diagnostics.runtimeDirectory.path)."
            await publishStartupFailure(detail, diagnostics: diagnosticSummary(readiness: readiness))
            throw NSError(domain: "ParakeetService", code: 3, userInfo: [
                NSLocalizedDescriptionKey: detail
            ])
        }

        let binaryPath = settings.parakeetBinaryPath
        if !FileManager.default.isExecutableFile(atPath: binaryPath) {
            let message = "Superkeet could not find a runnable bundled speech engine at \(binaryPath). Reinstall the app to restore the embedded engine."
            await publishStartupFailure(message, diagnostics: diagnosticSummary(readiness: readiness))
            throw NSError(domain: "ParakeetService", code: 1, userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        }

        await MainActor.run { daemonState = .starting }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)

        var args = [
            "serve",
            "--socket", settings.socketPath,
            "--pid-file", settings.pidFilePath,
        ]

        if !settings.audioInputDevice.isEmpty {
            args.append(contentsOf: ["--device", settings.audioInputDevice])
        }

        if !settings.modelDirectory.isEmpty {
            args.append(contentsOf: ["--model-dir", settings.modelDirectory])
        }

        process.arguments = args

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        self.stdoutPipe = stdout
        self.stderrPipe = stderr
        self.stderrBuffer = ""

        // Read stdout for transcriptions
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.handleDaemonOutput(text)
            }
        }

        // Read stderr for status messages
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.appendStderr(text)
            }
            print("[parakeet stderr] \(text)", terminator: "")
        }

        process.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let previousState = self.daemonState

                if previousState == .starting {
                    let detail = "Parakeet exited during startup with code \(proc.terminationStatus)."
                    let diagnostics = self.recentStderrExcerpt()
                    self.lastUserFacingError = diagnostics.map { "\(detail)\n\n\($0)" } ?? detail
                    self.lastDiagnosticsSummary = diagnostics
                    self.startupStatusDetail = "Startup failed"
                    self.settings.runtimeIssue = self.lastUserFacingError
                } else if previousState == .idle || previousState == .recording {
                    // Unexpected crash — notify user and attempt auto-restart
                    let message = "Speech engine exited unexpectedly (code \(proc.terminationStatus)). Restarting..."
                    print("[ParakeetService] \(message)")
                    self.settings.runtimeIssue = message
                }

                // Clear pipe handlers in case stopDaemon wasn't called
                self.stdoutPipe?.fileHandleForReading.readabilityHandler = nil
                self.stderrPipe?.fileHandleForReading.readabilityHandler = nil
                self.stdoutPipe = nil
                self.stderrPipe = nil

                self.daemonState = .stopped
                self.lifecycleLock.withLock {
                    self.daemonProcess = nil
                }
                self.settings.isDaemonRunning = false
                self.settings.isRecording = false

                if previousState == .idle || previousState == .recording {
                    self.scheduleAutoRestart(afterUnexpectedExitOf: proc)
                }
            }
        }

        do {
            try process.run()
        } catch {
            let detail = "Superkeet could not launch Parakeet at \(binaryPath). \(error.localizedDescription)"
            await publishStartupFailure(detail, diagnostics: diagnosticSummary(readiness: readiness))
            throw error
        }
        lifecycleLock.withLock {
            self.daemonProcess = process
        }

        do {
            try await waitForDaemonReadiness(process: process)

            guard FileManager.default.fileExists(atPath: settings.socketPath) else {
                let message = "Parakeet launched but never created its socket at \(settings.socketPath)."
                await publishStartupFailure(message, diagnostics: recentStderrExcerpt())
                throw NSError(domain: "ParakeetService", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: lastUserFacingError ?? message
                ])
            }
        } catch {
            await cleanupFailedStartup(process)
            throw error
        }

        await MainActor.run {
            self.daemonState = .idle
            self.settings.isDaemonRunning = true
            self.startupStatusDetail = "Ready"
            self.settings.runtimeIssue = nil
            self.settings.hasVerifiedSetup = readiness.passesSetupSmokeTest(
                daemonStarted: true,
                autoPasteEnabled: self.settings.autoPasteEnabled
            )
        }
        autoRestartPolicy.reset()
    }

    func stopDaemon() {
        Task {
            await stopDaemonAndWait()
        }
    }

    func stopDaemonAndWait() async {
        let pendingStart = lifecycleLock.withLock { startTask }
        if let pendingStart {
            _ = try? await pendingStart.value
        }

        if let pendingStop = lifecycleLock.withLock({ stopTask }) {
            await pendingStop.value
            return
        }

        let task = Task { await self.performStopDaemon() }
        lifecycleLock.withLock {
            stopTask = task
        }

        defer {
            lifecycleLock.withLock {
                stopTask = nil
            }
        }

        await task.value
    }

    private func performStopDaemon() async {
        idleShutdownTask?.cancel()
        idleShutdownTask = nil
        autoRestartTask?.cancel()
        autoRestartTask = nil

        await MainActor.run {
            self.daemonState = .stopping
            self.stdoutPipe?.fileHandleForReading.readabilityHandler = nil
            self.stderrPipe?.fileHandleForReading.readabilityHandler = nil
            self.stdoutPipe = nil
            self.stderrPipe = nil
        }

        let process = lifecycleLock.withLock { daemonProcess }
        if let process, process.isRunning {
            sendSocketCommand("shutdown")
            try? await Task.sleep(for: .milliseconds(500))
            await terminateRunningProcess(process)
        }

        lifecycleLock.withLock {
            daemonProcess = nil
        }
        await MainActor.run {
            self.daemonState = .stopped
            self.settings.isDaemonRunning = false
            self.settings.isRecording = false
            self.startupStatusDetail = "Stopped"
        }
    }

    private func cleanupFailedStartup(_ process: Process) async {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil

        await MainActor.run {
            self.daemonState = .stopped
            self.settings.isDaemonRunning = false
            self.settings.isRecording = false
        }

        await terminateRunningProcess(process)

        lifecycleLock.withLock {
            if daemonProcess === process {
                daemonProcess = nil
            }
        }
    }

    func restartDaemon() async throws {
        await stopDaemonAndWait()
        try await startDaemon()
    }

    // MARK: - Stale Process Cleanup

    /// Kill any orphaned parakeet serve processes from previous runs.
    /// Only terminates a validated stale PID from Superkeet's own runtime state.
    private func killStaleProcesses() async {
        let pidPath = settings.pidFilePath
        let socketPath = settings.socketPath

        // 1. Try to kill via PID file if it still points at the bundled engine.
        if let pidString = try? String(contentsOfFile: pidPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = Int32(pidString), pid > 0 {
            if isExpectedParakeetProcess(pid: pid) {
                print("[ParakeetService] Found stale validated PID file (pid: \(pid)), killing...")
                await terminateProcess(pid: pid)
            }
        }

        // 2. Remove stale files owned by this app runtime.
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: pidPath)

        // Brief pause to let the OS release the socket
        try? await Task.sleep(for: .milliseconds(200))
    }

    // MARK: - Recording Control

    @MainActor
    func startRecording() {
        // Cancel any pending idle shutdown since the user is active
        idleShutdownTask?.cancel()
        idleShutdownTask = nil

        // Capture the frontmost app before we do anything
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            activeAppAtRecordingStart = (
                name: frontApp.localizedName ?? "Unknown",
                bundleId: frontApp.bundleIdentifier ?? ""
            )
        }
        recordingStartTime = Date()
        lastDeliveredTranscription = nil

        sendSocketCommand("start") { [weak self] response in
            DispatchQueue.main.async {
                guard let envelope = self?.decodeSocketResponse(response),
                      envelope.status == "ok",
                      envelope.state == "recording" else {
                    return
                }

                self?.daemonState = .recording
                self?.settings.isRecording = true
            }
        }
    }

    @MainActor
    func stopRecording() {
        sendSocketCommand("stop") { [weak self] response in
            DispatchQueue.main.async {
                guard let envelope = self?.decodeSocketResponse(response),
                      envelope.status == "ok" else {
                    return
                }

                if envelope.state == "stopping" || envelope.state == "idle" {
                    self?.daemonState = .idle
                    self?.settings.isRecording = false
                    self?.resetIdleTimer()
                }
            }
        }
    }

    @MainActor
    func cancelRecording() {
        sendSocketCommand("cancel") { [weak self] response in
            DispatchQueue.main.async {
                guard let envelope = self?.decodeSocketResponse(response),
                      envelope.status == "ok" else {
                    return
                }

                if envelope.state == "idle" || envelope.state == "cancelling" {
                    self?.daemonState = .idle
                    self?.settings.isRecording = false
                    self?.recordingStartTime = nil
                    self?.activeAppAtRecordingStart = nil
                    self?.resetIdleTimer()
                }
            }
        }
    }

    @MainActor
    func toggleRecording() {
        if settings.isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func queryStatus(completion: ((String) -> Void)? = nil) {
        sendSocketCommand("status", completion: completion)
    }

    @MainActor
    func refreshDiagnostics() {
        let readiness = AppReadiness.current(settings: settings)
        lastDiagnosticsSummary = diagnosticSummary(readiness: readiness)
    }

    // MARK: - Idle Shutdown

    /// Schedule a daemon shutdown after the configured idle timeout.
    /// Called after each recording stops. Cancelled when a new recording starts.
    @MainActor
    private func resetIdleTimer() {
        idleShutdownTask?.cancel()
        idleShutdownTask = nil

        let timeoutMinutes = settings.idleTimeoutMinutes
        guard timeoutMinutes > 0 else { return }

        let task = DispatchWorkItem { [weak self] in
            guard let self = self, self.daemonState == .idle else { return }
            print("[ParakeetService] Idle timeout reached (\(timeoutMinutes) min), stopping daemon to reclaim resources")
            self.stopDaemon()
        }
        idleShutdownTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(timeoutMinutes * 60), execute: task)
    }

    // MARK: - Socket Communication

    private struct SocketCommand: Encodable {
        let command: String
    }

    private struct SocketResponseEnvelope: Decodable {
        let status: String
        let state: String?
    }

    private func decodeSocketResponse(_ response: String) -> SocketResponseEnvelope? {
        guard let data = response.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SocketResponseEnvelope.self, from: data)
    }

    private func sendSocketCommand(_ command: String, completion: ((String) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let timeout = timeval(tv_sec: 5, tv_usec: 0)
            let response = self.sendSocketCommandSynchronously(
                command,
                timeout: timeout,
                publishConnectionErrors: true
            )
            completion?(response ?? "")
        }
    }

    private func sendSocketCommandSynchronously(
        _ command: String,
        timeout requestedTimeout: timeval,
        publishConnectionErrors: Bool
    ) -> String? {
        let socketPath = settings.socketPath

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            print("[ParakeetService] Failed to create socket")
            return nil
        }
        defer { close(fd) }

        #if os(macOS)
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        #endif

        var timeout = requestedTimeout
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        guard let addr = unixSocketAddress(for: socketPath) else {
            let message = "Superkeet's runtime socket path is too long for macOS Unix sockets. Move the app/runtime directory to a shorter path."
            print("[ParakeetService] \(message) Path: \(socketPath)")
            if publishConnectionErrors {
                publishRuntimeIssue(message)
            }
            return nil
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        var mutableAddr = addr
        let connectResult = withUnsafePointer(to: &mutableAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, addrLen)
            }
        }

        guard connectResult == 0 else {
            print("[ParakeetService] Failed to connect to socket at \(socketPath): \(errno)")
            if publishConnectionErrors {
                publishRuntimeIssue("Superkeet could not reach the speech engine. Try relaunching the app.")
            }
            return nil
        }

        guard let jsonData = try? JSONEncoder().encode(SocketCommand(command: command)),
              var json = String(data: jsonData, encoding: .utf8) else {
            print("[ParakeetService] Failed to encode socket command")
            return nil
        }
        json.append("\n")

        let sentAllBytes = json.withCString { cstr in
            let byteCount = strlen(cstr)
            return send(fd, cstr, byteCount, 0) == byteCount
        }

        guard sentAllBytes else {
            print("[ParakeetService] Failed to send socket command '\(command)' to daemon")
            return nil
        }

        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = recv(fd, &buffer, buffer.count - 1, 0)
        if bytesRead > 0 {
            let response = String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""
            print("[ParakeetService] Response: \(response)")
            return response
        }

        print("[ParakeetService] recv returned \(bytesRead) (timeout or error)")
        return nil
    }

    private func unixSocketAddress(for socketPath: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = socketPath.utf8CString
        let maxSocketPathBytes = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= maxSocketPathBytes else { return nil }

        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: Int8.self, capacity: maxSocketPathBytes) { dst in
                pathBytes.withUnsafeBufferPointer { src in
                    for i in 0..<src.count {
                        dst[i] = src[i]
                    }
                }
            }
        }

        return addr
    }

    private func publishRuntimeIssue(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.lastUserFacingError = message
            self?.settings.runtimeIssue = message
        }
    }

    // MARK: - Output Handling

    private func handleDaemonOutput(_ text: String) {
        outputBuffer += text
        if outputBuffer.count > Self.maxBufferedOutputCharacters {
            outputBuffer = String(outputBuffer.suffix(Self.maxBufferedOutputCharacters))
        }

        // The daemon outputs transcription text on stdout when a session ends
        let lines = outputBuffer.components(separatedBy: "\n")
        if lines.count > 1 {
            for line in lines.dropLast() {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    processTranscription(trimmed)
                }
            }
            outputBuffer = lines.last ?? ""
        }
    }

    private func processTranscription(_ text: String) {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Apply filler word removal if enabled
        if settings.fillerWordRemovalEnabled {
            trimmed = FillerWordCleaner.clean(trimmed)
            guard !trimmed.isEmpty else { return }
        }

        if lastDeliveredTranscription == trimmed {
            return
        }

        lastTranscription = trimmed
        lastDeliveredTranscription = trimmed

        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        let appInfo = activeAppAtRecordingStart ?? (name: "Unknown", bundleId: "")

        let record = TranscriptionRecord(
            text: trimmed,
            durationSeconds: duration,
            activeAppName: appInfo.name,
            activeAppBundleId: appInfo.bundleId
        )

        // Record privacy-safe aggregate metrics (numbers only, no text)
        // regardless of whether history saving is enabled.
        UsageStatsStore.shared.record(wordCount: record.wordCount, durationSeconds: duration)

        let outputDecision = OutputRouting.decision(
            clipboardCopyEnabled: settings.clipboardCopyEnabled,
            autoPasteEnabled: settings.autoPasteEnabled,
            saveHistoryEnabled: settings.saveHistoryEnabled
        )

        if outputDecision.shouldSaveHistory {
            HistoryStore.shared.addRecord(record)
        }

        if outputDecision.shouldCopyToClipboard {
            PasteService.shared.deliverText(trimmed)
        }

        // Reset
        recordingStartTime = nil
        activeAppAtRecordingStart = nil
    }

    // MARK: - Cleanup

    func cleanup() {
        Task {
            await cleanupAndWait()
        }
    }

    func cleanupAndWait() async {
        await stopDaemonAndWait()
        // Clean up socket and pid files
        try? FileManager.default.removeItem(atPath: settings.socketPath)
        try? FileManager.default.removeItem(atPath: settings.pidFilePath)
    }

    private func ensureRuntimeDirectory() throws {
        let directory = AppReadiness.runtimeFilesDirectory()
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let probeURL = directory.appendingPathComponent(".runtime-probe")
            try "ok".data(using: .utf8)?.write(to: probeURL)
            try? fileManager.removeItem(at: probeURL)
        } catch {
            let detail = "Superkeet could not prepare its runtime directory at \(directory.path). \(error.localizedDescription)"
            Task { @MainActor in
                await self.publishStartupFailure(detail, diagnostics: nil)
            }
            throw NSError(domain: "ParakeetService", code: 4, userInfo: [
                NSLocalizedDescriptionKey: detail
            ])
        }
    }

    private func waitForDaemonReadiness(process: Process) async throws {
        let deadline = ContinuousClock.now + .nanoseconds(Int64(Self.startupTimeoutNanoseconds))

        while ContinuousClock.now < deadline {
            if FileManager.default.fileExists(atPath: settings.socketPath) {
                if try await probeSocketReadiness() {
                    return
                }
            }

            if !process.isRunning {
                let detail = "Parakeet exited during startup with code \(process.terminationStatus)."
                await publishStartupFailure(detail, diagnostics: recentStderrExcerpt())
                throw NSError(domain: "ParakeetService", code: 5, userInfo: [
                    NSLocalizedDescriptionKey: lastUserFacingError ?? detail
                ])
            }

            await MainActor.run {
                self.startupStatusDetail = self.derivedStartupStatus()
            }

            try await Task.sleep(nanoseconds: Self.startupPollIntervalNanoseconds)
        }

        let detail = "Parakeet did not become ready within \(Self.startupTimeoutNanoseconds / 1_000_000_000) seconds."
        await publishStartupFailure(detail, diagnostics: recentStderrExcerpt())
        throw NSError(domain: "ParakeetService", code: 6, userInfo: [
            NSLocalizedDescriptionKey: lastUserFacingError ?? detail
        ])
    }

    private func probeSocketReadiness() async throws -> Bool {
        let timeout = timeval(tv_sec: 0, tv_usec: 300_000)
        let response = sendSocketCommandSynchronously(
            "status",
            timeout: timeout,
            publishConnectionErrors: false
        )
        return response?.contains("\"status\":\"ok\"") == true
    }

    @MainActor
    private func publishStartupFailure(_ detail: String, diagnostics: String?) async {
        let message = diagnostics.map { "\(detail)\n\n\($0)" } ?? detail
        lastUserFacingError = message
        lastDiagnosticsSummary = diagnostics
        startupStatusDetail = "Startup failed"
        settings.runtimeIssue = message
    }

    private func appendStderr(_ text: String) {
        stderrBuffer += text
        let lines = stderrBuffer.components(separatedBy: .newlines)
        if lines.count > 25 {
            stderrBuffer = lines.suffix(25).joined(separator: "\n")
        }
        startupStatusDetail = derivedStartupStatus()
    }

    private func recentStderrExcerpt() -> String? {
        let trimmed = stderrBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return "Parakeet stderr:\n\(trimmed)"
    }

    private func derivedStartupStatus() -> String {
        let stderr = stderrBuffer.lowercased()
        if stderr.contains("ready. waiting for commands") {
            return "Ready"
        }
        if stderr.contains("listening on socket") {
            return "Waiting for daemon response"
        }
        if stderr.contains("loading parakeet model") {
            return "Loading model"
        }
        if stderr.contains("silero") {
            return "Loading VAD"
        }
        return "Starting daemon"
    }

    private func terminateProcess(pid: pid_t) async {
        guard kill(pid, 0) == 0 else { return }
        kill(pid, SIGTERM)
        try? await Task.sleep(for: .milliseconds(500))
        if kill(pid, 0) == 0 {
            kill(pid, SIGKILL)
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func terminateRunningProcess(_ process: Process) async {
        guard process.isRunning else { return }

        process.terminate()
        if await waitForProcessToExit(process, timeoutNanoseconds: 2_000_000_000) {
            return
        }

        let pid = process.processIdentifier
        if kill(pid, 0) == 0 {
            kill(pid, SIGKILL)
            _ = await waitForProcessToExit(process, timeoutNanoseconds: 1_000_000_000)
        }
    }

    private func waitForProcessToExit(_ process: Process, timeoutNanoseconds: UInt64) async -> Bool {
        let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))

        while process.isRunning && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }

        return !process.isRunning
    }

    @MainActor
    private func scheduleAutoRestart(afterUnexpectedExitOf process: Process) {
        guard let delay = autoRestartPolicy.nextDelay() else {
            settings.runtimeIssue = "Speech engine exited repeatedly. Open Settings to review diagnostics before restarting it again."
            startupStatusDetail = "Restart paused"
            return
        }

        let message = "Speech engine exited unexpectedly (code \(process.terminationStatus)). Restarting in \(Int(delay))s..."
        print("[ParakeetService] \(message)")
        settings.runtimeIssue = message

        autoRestartTask?.cancel()
        autoRestartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            do {
                try await self?.startDaemon()
                await MainActor.run {
                    self?.settings.runtimeIssue = nil
                }
            } catch {
                await MainActor.run {
                    self?.settings.runtimeIssue = "Failed to restart speech engine: \(error.localizedDescription)"
                }
            }
        }
    }

    private func isExpectedParakeetProcess(pid: pid_t) -> Bool {
        guard let executablePath = processExecutablePath(pid: pid) else { return false }
        let normalizedExecutable = URL(fileURLWithPath: executablePath).standardizedFileURL.path
        let normalizedExpected = URL(fileURLWithPath: settings.parakeetBinaryPath).standardizedFileURL.path
        return normalizedExecutable == normalizedExpected
    }

    private func processExecutablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard result > 0 else { return nil }
        return String(cString: buffer)
    }

    private func diagnosticSummary(readiness: AppReadinessReport) -> String {
        let diagnostics = readiness.diagnostics
        let microphoneStatus: String
        switch diagnostics.microphoneStatus {
        case .authorized: microphoneStatus = "authorized"
        case .denied: microphoneStatus = "denied"
        case .restricted: microphoneStatus = "restricted"
        case .notDetermined: microphoneStatus = "not determined"
        @unknown default: microphoneStatus = "unknown"
        }

        let deviceSummary = diagnostics.availableInputDeviceNames.isEmpty
            ? "none"
            : diagnostics.availableInputDeviceNames.joined(separator: ", ")

        return """
        Diagnostics:
        - Microphone: \(microphoneStatus)
        - Engine binary: \(diagnostics.engineBinaryExists ? "found" : "missing")
        - Runtime directory: \(diagnostics.runtimeDirectoryWritable ? "writable" : "not writable") at \(diagnostics.runtimeDirectory.path)
        - Available input devices: \(deviceSummary)
        """
    }
}

private extension NSLock {
    func withLock<T>(_ work: () -> T) -> T {
        lock()
        defer { unlock() }
        return work()
    }
}
