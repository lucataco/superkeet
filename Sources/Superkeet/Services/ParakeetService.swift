import Foundation
import AppKit

/// Manages the parakeet serve daemon subprocess and communicates via Unix socket
final class ParakeetService: ObservableObject {
    static let shared = ParakeetService()
    private static let startupPollIntervalNanoseconds: UInt64 = 100_000_000
    private static let startupTimeoutNanoseconds: UInt64 = 20_000_000_000

    @Published var isBuilding: Bool = false
    @Published var buildError: String?
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

    private init() {}

    // MARK: - Build

    func buildParakeetCLI() async throws {
        await MainActor.run { isBuilding = true; buildError = nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["cargo", "build", "--release"]
        process.currentDirectoryURL = URL(fileURLWithPath: settings.parakeetProjectDirectory)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Drain pipes asynchronously to avoid deadlock when output exceeds the 64KB buffer.
        // Use a serial dispatch queue for thread-safe accumulation (avoids NSLock in async context).
        let collectQueue = DispatchQueue(label: "com.superkeet.build-output")
        var outputData = Data()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            collectQueue.sync { outputData.append(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            collectQueue.sync { outputData.append(data) }
        }

        try process.run()
        process.waitUntilExit()

        // Stop reading handlers and collect final output
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        let output: String = collectQueue.sync {
            String(data: outputData, encoding: .utf8) ?? ""
        }

        if process.terminationStatus != 0 {
            await MainActor.run {
                self.isBuilding = false
                self.buildError = "Build failed (exit \(process.terminationStatus)):\n\(output)"
            }
            throw NSError(domain: "ParakeetService", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Build failed: \(output)"
            ])
        }

        await MainActor.run {
            self.isBuilding = false
            self.buildError = nil
        }
    }

    // MARK: - Daemon Management

    func startDaemon() async throws {
        guard daemonProcess == nil else { return }
        await MainActor.run {
            self.lastUserFacingError = nil
            self.lastDiagnosticsSummary = nil
            self.startupStatusDetail = "Starting daemon"
            self.settings.runtimeIssue = nil
        }

        // Kill any orphaned daemon from a previous run
        killStaleProcesses()

        try ensureRuntimeDirectory()

        let readiness = AppReadiness.current(settings: settings)
        if readiness.hasDaemonBlockingIssue {
            let detail = readiness.issues.contains(.engine)
                ? "Superkeet could not find the Parakeet engine at \(settings.parakeetBinaryPath). Build or bundle the engine first."
                : "Superkeet could not prepare its runtime directory at \(readiness.diagnostics.runtimeDirectory.path)."
            await publishStartupFailure(detail, diagnostics: diagnosticSummary(readiness: readiness))
            throw NSError(domain: "ParakeetService", code: 3, userInfo: [
                NSLocalizedDescriptionKey: detail
            ])
        }

        let binaryPath = settings.parakeetBinaryPath
        if !FileManager.default.fileExists(atPath: binaryPath) {
            let message = "Superkeet could not find the Parakeet engine at \(binaryPath). Build or bundle the engine first."
            await publishStartupFailure(message, diagnostics: diagnosticSummary(readiness: readiness))
            try await buildParakeetCLI()
        }

        await MainActor.run { daemonState = .starting }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)

        var args = [
            "serve",
            "--socket", settings.socketPath,
            "--pid-file", settings.pidFilePath,
        ]

        if settings.clipboardCopyEnabled {
            args.append("--clipboard")
        }

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
                if self?.daemonState == .starting {
                    let detail = "Parakeet exited during startup with code \(proc.terminationStatus)."
                    let diagnostics = self?.recentStderrExcerpt()
                    self?.lastUserFacingError = diagnostics == nil ? detail : "\(detail)\n\n\(diagnostics!)"
                    self?.lastDiagnosticsSummary = diagnostics
                    self?.startupStatusDetail = "Startup failed"
                    self?.settings.runtimeIssue = self?.lastUserFacingError
                }
                self?.daemonState = .stopped
                self?.daemonProcess = nil
                self?.settings.isDaemonRunning = false
                self?.settings.isRecording = false
            }
        }

        do {
            try process.run()
        } catch {
            let detail = "Superkeet could not launch Parakeet at \(binaryPath). \(error.localizedDescription)"
            await publishStartupFailure(detail, diagnostics: diagnosticSummary(readiness: readiness))
            throw error
        }
        self.daemonProcess = process

        try await waitForDaemonReadiness(process: process)

        guard FileManager.default.fileExists(atPath: settings.socketPath) else {
            process.terminate()
            let message = "Parakeet launched but never created its socket at \(settings.socketPath)."
            await publishStartupFailure(message, diagnostics: recentStderrExcerpt())
            await MainActor.run {
                self.daemonState = .stopped
                self.settings.isDaemonRunning = false
            }
            throw NSError(domain: "ParakeetService", code: 2, userInfo: [
                NSLocalizedDescriptionKey: lastUserFacingError ?? message
            ])
        }

        await MainActor.run {
            self.daemonState = .idle
            self.settings.isDaemonRunning = true
            self.startupStatusDetail = "Ready"
            self.settings.runtimeIssue = nil
        }
    }

    func stopDaemon() {
        // Try graceful shutdown via socket
        sendSocketCommand("shutdown")

        if let process = daemonProcess, process.isRunning {
            process.terminate()
            // Wait up to 2 seconds on a background thread instead of blocking main with Thread.sleep
            let waitItem = DispatchWorkItem { process.waitUntilExit() }
            DispatchQueue.global(qos: .userInitiated).async(execute: waitItem)
            let finished = waitItem.wait(timeout: .now() + 2.0)
            if finished == .timedOut && process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }

        daemonProcess = nil
        daemonState = .stopped
        settings.isDaemonRunning = false
        settings.isRecording = false
    }

    func restartDaemon() async throws {
        stopDaemon()
        try await startDaemon()
    }

    // MARK: - Stale Process Cleanup

    /// Kill any orphaned parakeet-cli serve processes from previous runs.
    /// Checks the PID file first, then does a broad pkill as a safety net.
    private func killStaleProcesses() {
        let pidPath = settings.pidFilePath
        let socketPath = settings.socketPath

        // 1. Try to kill via PID file
        if let pidString = try? String(contentsOfFile: pidPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = Int32(pidString), pid > 0 {
            print("[ParakeetService] Found stale PID file (pid: \(pid)), killing...")
            kill(pid, SIGTERM)
            // Wait briefly for graceful exit
            Thread.sleep(forTimeInterval: 0.5)
            // Force kill if still alive
            if kill(pid, 0) == 0 {  // kill with signal 0 checks if process exists
                kill(pid, SIGKILL)
                Thread.sleep(forTimeInterval: 0.2)
            }
        }

        // 2. Broad cleanup: kill any parakeet-cli serve processes owned by this user
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-U", String(getuid()), "-f", "parakeet-cli serve"]
        try? pkill.run()
        pkill.waitUntilExit()

        // 3. Remove stale files
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: pidPath)

        // Brief pause to let the OS release the socket
        Thread.sleep(forTimeInterval: 0.2)
    }

    // MARK: - Recording Control

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
                if response.contains("recording") || response.contains("ok") {
                    self?.daemonState = .recording
                    self?.settings.isRecording = true
                }
            }
        }
    }

    func stopRecording() {
        sendSocketCommand("stop") { [weak self] response in
            DispatchQueue.main.async {
                self?.daemonState = .idle
                self?.settings.isRecording = false
                self?.resetIdleTimer()
            }
        }
    }

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

    func refreshDiagnostics() {
        let readiness = AppReadiness.current(settings: settings)
        lastDiagnosticsSummary = diagnosticSummary(readiness: readiness)
    }

    // MARK: - Idle Shutdown

    /// Schedule a daemon shutdown after the configured idle timeout.
    /// Called after each recording stops. Cancelled when a new recording starts.
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

    private func sendSocketCommand(_ command: String, completion: ((String) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let socketPath = self.settings.socketPath

            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else {
                print("[ParakeetService] Failed to create socket")
                completion?("")
                return
            }
            defer { close(fd) }

            // Set a 5-second receive timeout to prevent blocking a GCD thread forever
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = socketPath.utf8CString
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                ptr.withMemoryRebound(to: Int8.self, capacity: 104) { dst in
                    pathBytes.withUnsafeBufferPointer { src in
                        let count = min(src.count, 104)
                        for i in 0..<count {
                            dst[i] = src[i]
                        }
                    }
                }
            }

            let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let connectResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    connect(fd, sockPtr, addrLen)
                }
            }

            guard connectResult == 0 else {
                print("[ParakeetService] Failed to connect to socket at \(socketPath): \(errno)")
                DispatchQueue.main.async {
                    self.lastUserFacingError = "Superkeet could not reach the speech engine. Try relaunching the app."
                    self.settings.runtimeIssue = self.lastUserFacingError
                    self.daemonState = .stopped
                    self.settings.isDaemonRunning = false
                }
                completion?("")
                return
            }

            // Send the command as JSON
            guard let jsonData = try? JSONEncoder().encode(SocketCommand(command: command)),
                  var json = String(data: jsonData, encoding: .utf8) else {
                print("[ParakeetService] Failed to encode socket command")
                completion?("")
                return
            }
            json.append("\n")
            json.withCString { cstr in
                _ = send(fd, cstr, strlen(cstr), 0)
            }

            // Read response
            var buffer = [UInt8](repeating: 0, count: 4096)
            let bytesRead = recv(fd, &buffer, buffer.count - 1, 0)
            if bytesRead > 0 {
                let response = String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""
                print("[ParakeetService] Response: \(response)")
                completion?(response)
            } else {
                print("[ParakeetService] recv returned \(bytesRead) (timeout or error)")
                completion?("")
            }
        }
    }

    // MARK: - Output Handling

    private func handleDaemonOutput(_ text: String) {
        outputBuffer += text

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

        let outputDecision = OutputRouting.decision(
            clipboardCopyEnabled: settings.clipboardCopyEnabled,
            autoPasteEnabled: settings.autoPasteEnabled,
            saveHistoryEnabled: settings.saveHistoryEnabled
        )

        if outputDecision.shouldSaveHistory {
            HistoryStore.shared.addRecord(record)
        }

        if outputDecision.shouldCopyToClipboard || outputDecision.shouldAutoPaste {
            PasteService.shared.deliverText(trimmed)
        }

        // Reset
        recordingStartTime = nil
        activeAppAtRecordingStart = nil
    }

    // MARK: - Cleanup

    /// Synchronous cleanup — safe to call from signal handlers and applicationWillTerminate.
    /// Kills the daemon process and removes socket/PID files.
    func cleanup() {
        stopDaemon()
        // Clean up socket and pid files
        try? FileManager.default.removeItem(atPath: settings.socketPath)
        try? FileManager.default.removeItem(atPath: settings.pidFilePath)

        // Safety net: kill any remaining parakeet-cli serve processes owned by this user
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-U", String(getuid()), "-f", "parakeet-cli serve"]
        try? pkill.run()
        pkill.waitUntilExit()
    }

    private func ensureRuntimeDirectory() throws {
        let directory = AppReadiness.runtimeFilesDirectory()
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
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
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { [weak self] in
                await withCheckedContinuation { continuation in
                    self?.sendSocketCommand("status") { response in
                        continuation.resume(returning: response.contains("\"status\":\"ok\""))
                    }
                }
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: 300_000_000)
                return false
            }

            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    @MainActor
    private func publishStartupFailure(_ detail: String, diagnostics: String?) async {
        let message = diagnostics == nil ? detail : "\(detail)\n\n\(diagnostics!)"
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
