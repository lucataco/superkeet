import Foundation
import AppKit

/// Manages the parakeet serve daemon subprocess and communicates via Unix socket
final class ParakeetService: ObservableObject {
    static let shared = ParakeetService()

    @Published var isBuilding: Bool = false
    @Published var buildError: String?
    @Published var daemonState: DaemonState = .stopped
    @Published var lastTranscription: String = ""

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
    private var recordingStartTime: Date?
    private var activeAppAtRecordingStart: (name: String, bundleId: String)?

    private init() {}

    // MARK: - Build

    func buildParakeetCLI() async throws {
        await MainActor.run { isBuilding = true; buildError = nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["cargo", "build", "--release"]
        process.currentDirectoryURL = URL(fileURLWithPath: settings.parakeetCliPath)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

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

        // Kill any orphaned daemon from a previous run
        killStaleProcesses()

        let binaryPath = settings.parakeetBinaryPath
        if !FileManager.default.fileExists(atPath: binaryPath) {
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

        process.arguments = args

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        self.stdoutPipe = stdout
        self.stderrPipe = stderr

        // Read stdout for transcriptions
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self?.handleDaemonOutput(text)
            }
        }

        // Read stderr for status messages
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            print("[parakeet stderr] \(text)", terminator: "")
        }

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                self?.daemonState = .stopped
                self?.daemonProcess = nil
                self?.settings.isDaemonRunning = false
                self?.settings.isRecording = false
            }
        }

        try process.run()
        self.daemonProcess = process

        // Wait a moment for the socket to be ready
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5s

        await MainActor.run {
            self.daemonState = .idle
            self.settings.isDaemonRunning = true
        }
    }

    func stopDaemon() {
        // Try graceful shutdown via socket
        sendSocketCommand("shutdown")

        // Give it a brief moment, then force kill synchronously
        Thread.sleep(forTimeInterval: 0.5)

        if let process = daemonProcess, process.isRunning {
            process.terminate()
            // Wait up to 2 seconds for the process to exit
            let deadline = Date().addingTimeInterval(2.0)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            // If still alive, SIGKILL
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }

        daemonProcess = nil
        daemonState = .stopped
        settings.isDaemonRunning = false
        settings.isRecording = false
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

        // 2. Broad cleanup: kill any parakeet-cli serve processes
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", "parakeet-cli serve"]
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
        // Capture the frontmost app before we do anything
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            activeAppAtRecordingStart = (
                name: frontApp.localizedName ?? "Unknown",
                bundleId: frontApp.bundleIdentifier ?? ""
            )
        }
        recordingStartTime = Date()

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

    // MARK: - Socket Communication

    private func sendSocketCommand(_ command: String, completion: ((String) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let socketPath = self.settings.socketPath

            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else {
                print("[ParakeetService] Failed to create socket")
                return
            }
            defer { close(fd) }

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
                return
            }

            // Send the command as JSON
            let json = "{\"command\":\"\(command)\"}\n"
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
        lastTranscription = text

        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        let appInfo = activeAppAtRecordingStart ?? (name: "Unknown", bundleId: "")

        let record = TranscriptionRecord(
            text: text,
            durationSeconds: duration,
            activeAppName: appInfo.name,
            activeAppBundleId: appInfo.bundleId
        )

        HistoryStore.shared.addRecord(record)

        // Auto-paste if enabled
        if settings.autoPasteEnabled {
            PasteService.shared.pasteText(text)
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

        // Safety net: kill any remaining parakeet-cli serve processes
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", "parakeet-cli serve"]
        try? pkill.run()
        pkill.waitUntilExit()
    }
}
