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

    private init() {}

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
                guard let self = self else { return }
                let previousState = self.daemonState

                if previousState == .starting {
                    let detail = "Parakeet exited during startup with code \(proc.terminationStatus)."
                    let diagnostics = self.recentStderrExcerpt()
                    self.lastUserFacingError = diagnostics == nil ? detail : "\(detail)\n\n\(diagnostics!)"
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
                self.daemonProcess = nil
                self.settings.isDaemonRunning = false
                self.settings.isRecording = false

                // Auto-restart on unexpected crash (not during intentional stop or failed startup)
                if previousState == .idle || previousState == .recording {
                    Task {
                        // Brief delay before restart to avoid tight restart loops
                        try? await Task.sleep(for: .seconds(2))
                        do {
                            try await self.startDaemon()
                            await MainActor.run {
                                self.settings.runtimeIssue = nil
                            }
                        } catch {
                            await MainActor.run {
                                self.settings.runtimeIssue = "Failed to restart speech engine: \(error.localizedDescription)"
                            }
                        }
                    }
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
        daemonState = .stopping

        // Clear pipe handlers to avoid stale callbacks after termination
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil

        if let process = daemonProcess, process.isRunning {
            // Try graceful shutdown via socket, give it 500ms, then SIGTERM
            sendSocketCommand("shutdown")
            let pid = process.processIdentifier
            DispatchQueue.global(qos: .userInitiated).async {
                // Give the graceful shutdown a brief window
                Thread.sleep(forTimeInterval: 0.5)
                guard process.isRunning else { return }
                process.terminate()
                // Wait up to 2s for SIGTERM to take effect
                let waitItem = DispatchWorkItem { process.waitUntilExit() }
                DispatchQueue.global(qos: .userInitiated).async(execute: waitItem)
                let finished = waitItem.wait(timeout: .now() + 2.0)
                if finished == .timedOut && kill(pid, 0) == 0 {
                    kill(pid, SIGKILL)
                }
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

    private func terminateProcess(pid: pid_t) async {
        guard kill(pid, 0) == 0 else { return }
        kill(pid, SIGTERM)
        try? await Task.sleep(for: .milliseconds(500))
        if kill(pid, 0) == 0 {
            kill(pid, SIGKILL)
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func isExpectedParakeetProcess(pid: pid_t) -> Bool {
        guard let executablePath = processExecutablePath(pid: pid) else { return false }
        let normalizedExecutable = URL(fileURLWithPath: executablePath).standardizedFileURL.path
        let normalizedExpected = URL(fileURLWithPath: settings.parakeetBinaryPath).standardizedFileURL.path

        if normalizedExecutable == normalizedExpected {
            return true
        }

        return URL(fileURLWithPath: executablePath).lastPathComponent == "parakeet"
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
