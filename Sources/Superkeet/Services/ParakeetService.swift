import Foundation
import AppKit
import Darwin
import os.log

private let parakeetLog = Logger(subsystem: "com.superkeet.app", category: "ParakeetService")

final class ParakeetService: ObservableObject, @unchecked Sendable {
    static let shared = ParakeetService()
    private static let startupPollIntervalNanoseconds: UInt64 = 100_000_000
    private static let startupTimeoutNanoseconds: UInt64 = 20_000_000_000

    @Published var daemonState: DaemonState = .stopped
    @Published var lastTranscription: String = ""
    @Published var lastRawTranscription: String = ""
    @Published var sessionStatus: String = "Ready"
    @Published var canUndoTextChanges = false
    @Published var lastUserFacingError: String?
    @Published var lastDiagnosticsSummary: String?
    @Published var startupStatusDetail: String?
    @Published private(set) var daemonProtocolVersion: Int?
    /// Fires once per finished take so the overlay can confirm what happened to the text.
    @Published private(set) var lastOutcome: TranscriptOutcomeEvent?

    static let supportedProtocolVersions: Set<Int> = [1, 2]
    static let interimTextProtocolVersion = 2

    var daemonStreamsInterimText: Bool { daemonProtocolVersion == Self.interimTextProtocolVersion }

    enum DaemonState: String {
        case stopped
        case starting
        case idle
        case recording
        case transcribing
        case stopping
    }

    private var daemonProcess: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private let settings = AppSettings.shared
    private var outputStream = TranscriptEventStream()
    private var outputGeneration = UUID()
    private var stderrBuffer: String = ""
    private var recordingStartTime: Date?
    private var activeAppAtRecordingStart: (name: String, bundleId: String, processIdentifier: pid_t?)?
    private var outputGate = TranscriptSessionGate()
    private var recordingDuration: TimeInterval = 0
    private var completionTimeout: DispatchWorkItem?
    private var startRequestPending = false
    private var commandModeArmed = false
    private var idleShutdownTask: DispatchWorkItem?
    private let lifecycleLock = NSLock()
    private var startTask: Task<Void, Error>?
    private var stopTask: Task<Void, Never>?
    private var autoRestartTask: Task<Void, Never>?
    private var autoRestartPolicy = AutoRestartPolicy()
    @MainActor var speculativeLaunchingOverride: (any SpeculativeLaunching)?
    @MainActor private var interimContinuations: [String: AsyncStream<PartialTranscript>.Continuation] = [:]

    private init() {}

    @MainActor
    private var speculation: any SpeculativeLaunching {
        speculativeLaunchingOverride ?? SpeculativeLaunchCoordinator.shared
    }

    @MainActor
    private func endSpeculation() {
        guard let sessionID = outputGate.sessionID else { return }
        speculation.end(sessionID: sessionID)
    }

    @MainActor
    func interimTranscripts(sessionID: String) -> AsyncStream<PartialTranscript> {
        dispatchPrecondition(condition: .onQueue(.main))
        let (stream, continuation) = AsyncStream.makeStream(of: PartialTranscript.self)
        interimContinuations[sessionID]?.finish()
        interimContinuations[sessionID] = continuation
        return stream
    }

    @MainActor
    func endInterimTranscripts(sessionID: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        interimContinuations.removeValue(forKey: sessionID)?.finish()
    }

    @MainActor
    private func deliverInterim(_ event: TranscriptEvent) {
        guard daemonState == .recording, let interim = event.interimTranscript else { return }
        interimContinuations[event.sessionID]?.yield(interim)
    }

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
            self.outputStream = TranscriptEventStream()
            self.autoRestartTask?.cancel()
            self.autoRestartTask = nil
            self.settings.runtimeIssue = nil
        }

        await killStaleProcesses()
        try Task.checkCancellation()

        try ensureRuntimeDirectory()
        try Task.checkCancellation()

        if settings.canBootstrapDevelopmentParakeet {
            await MainActor.run { self.startupStatusDetail = "Preparing development speech engine" }
            do {
                _ = try await DevelopmentParakeetBootstrap.ensureAvailable(settings: settings)
            } catch {
                let readiness = AppReadiness.current(settings: settings)
                let detail = error.localizedDescription
                await publishStartupFailure(detail, diagnostics: diagnosticSummary(readiness: readiness))
                throw error
            }
        }

        let readiness = AppReadiness.current(settings: settings)
        if readiness.hasDaemonBlockingIssue {
            let detail = readiness.issues.contains(.engine)
                ? settings.missingParakeetBinaryMessage
                : "Superkeet could not prepare its runtime directory at \(readiness.diagnostics.runtimeDirectory.path)."
            await publishStartupFailure(detail, diagnostics: diagnosticSummary(readiness: readiness))
            throw NSError(domain: "ParakeetService", code: 3, userInfo: [
                NSLocalizedDescriptionKey: detail
            ])
        }

        let binaryPath = settings.parakeetBinaryPath
        if !FileManager.default.isExecutableFile(atPath: binaryPath) {
            let message = settings.missingParakeetBinaryMessage
            await publishStartupFailure(message, diagnostics: diagnosticSummary(readiness: readiness))
            throw NSError(domain: "ParakeetService", code: 1, userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        }

        if !ModelProvisioning.shared.isModelInstalled() {
            await MainActor.run { self.startupStatusDetail = "Downloading speech model" }
            do {
                try await ModelProvisioning.shared.ensureModelAvailable()
            } catch {
                let detail = "Superkeet could not download the on-device speech model. \(error.localizedDescription)"
                await publishStartupFailure(detail, diagnostics: diagnosticSummary(readiness: readiness))
                throw error
            }
        }
        try Task.checkCancellation()

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

        args.append(contentsOf: ["--model-dir", settings.effectiveModelDirectory])

        process.arguments = args

        let stdout = Pipe()
        let stderr = Pipe()
        let generation = UUID()
        process.standardOutput = stdout
        process.standardError = stderr
        await MainActor.run {
            self.stdoutPipe = stdout
            self.stderrPipe = stderr
            self.stderrBuffer = ""
            self.outputGeneration = generation
        }

        let deliverOutput: @MainActor @Sendable (Data) -> Void = { [weak self] data in
            guard let self, self.outputGeneration == generation else { return }
            self.handleDaemonOutput(data)
        }
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async {
                deliverOutput(data)
            }
        }

        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.appendStderr(text)
            }
            parakeetLog.info("parakeet stderr: \(text, privacy: .public)")
        }

        process.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                guard let self = self, self.outputGeneration == generation else { return }
                let previousState = self.daemonState

                if previousState == .starting {
                    let detail = "Parakeet exited during startup with code \(proc.terminationStatus)."
                    let diagnostics = self.recentStderrExcerpt()
                    self.lastUserFacingError = diagnostics.map { "\(detail)\n\n\($0)" } ?? detail
                    self.lastDiagnosticsSummary = diagnostics
                    self.startupStatusDetail = "Startup failed"
                    self.settings.runtimeIssue = self.lastUserFacingError
                } else if previousState == .idle || previousState == .recording || previousState == .transcribing {
                    let message = "Speech engine exited unexpectedly (code \(proc.terminationStatus)). Restarting..."
                    parakeetLog.warning("\(message, privacy: .public)")
                    self.settings.runtimeIssue = message
                }

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
                if self.outputGate.sessionID != nil {
                    self.failSession("The speech engine exited before transcription completed.")
                }

                if previousState == .idle || previousState == .recording || previousState == .transcribing {
                    self.scheduleAutoRestart(afterUnexpectedExitOf: proc)
                }
            }
        }

        try Task.checkCancellation()
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
                let diagnostics = await MainActor.run { self.recentStderrExcerpt() }
                await publishStartupFailure(message, diagnostics: diagnostics)
                throw NSError(domain: "ParakeetService", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: message
                ])
            }
        } catch {
            await cleanupFailedStartup(process)
            throw error
        }

        // Reuse the pre-launch readiness scan; the only thing that can change during startup is
        // the model install state, which we know succeeded if we got here.
        let finalReadiness = readiness.needsModelDownload
            ? AppReadiness.current(settings: settings)
            : readiness

        await MainActor.run {
            self.daemonState = .idle
            self.settings.isDaemonRunning = true
            self.startupStatusDetail = "Ready"
            self.settings.runtimeIssue = nil
            self.settings.hasVerifiedSetup = finalReadiness.passesSetupSmokeTest(
                daemonStarted: true,
                autoPasteEnabled: self.settings.autoPasteEnabled
            )
            self.autoRestartPolicy.recordReady()
        }
    }

    func stopDaemon() {
        Task {
            await stopDaemonAndWait()
        }
    }

    func stopDaemonAndWait() async {
        let pendingStart = lifecycleLock.withLock { startTask }
        if let pendingStart {
            pendingStart.cancel()
            ModelProvisioning.shared.cancelInFlightDownload()
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
        await MainActor.run {
            self.idleShutdownTask?.cancel()
            self.idleShutdownTask = nil
            self.autoRestartTask?.cancel()
            self.autoRestartTask = nil
            if self.outputGate.sessionID != nil {
                self.failSession("Transcription interrupted because the speech engine stopped.")
            }
            self.daemonState = .stopping
            self.outputStream = TranscriptEventStream()
            self.stdoutPipe?.fileHandleForReading.readabilityHandler = nil
            self.stderrPipe?.fileHandleForReading.readabilityHandler = nil
            self.stdoutPipe = nil
            self.stderrPipe = nil
        }

        let process = lifecycleLock.withLock { daemonProcess }
        if let process, process.isRunning {
            sendSocketCommand("shutdown")
            // Poll for a graceful exit instead of sleeping a fixed interval; escalate only if needed.
            if !(await waitForProcessToExit(process, timeoutNanoseconds: 1_000_000_000)) {
                await terminateRunningProcess(process)
            }
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
            self.outputStream = TranscriptEventStream()
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

    private func killStaleProcesses() async {
        let pidPath = settings.pidFilePath
        let socketPath = settings.socketPath

        var killedStaleProcess = false
        if let pidString = try? String(contentsOfFile: pidPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = Int32(pidString), pid > 0 {
            if isExpectedParakeetProcess(pid: pid) {
                parakeetLog.info("Found stale validated PID file (pid: \(pid)), killing...")
                await terminateProcess(pid: pid)
                killedStaleProcess = true
            }
        }

        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: pidPath)

        // Only give the kernel time to release the socket if we actually tore down a process.
        if killedStaleProcess {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    @MainActor
    func armCommandMode() {
        dispatchPrecondition(condition: .onQueue(.main))
        commandModeArmed = true
    }

    @MainActor
    func disarmCommandMode() {
        dispatchPrecondition(condition: .onQueue(.main))
        commandModeArmed = false
    }

    @MainActor
    func startRecording() async -> Bool {
        guard daemonState == .idle, outputGate.sessionID == nil, !startRequestPending else { return false }
        startRequestPending = true
        defer { startRequestPending = false }
        let sessionID = UUID().uuidString
        guard outputGate.begin(sessionID) else { return false }
        idleShutdownTask?.cancel()
        idleShutdownTask = nil

        if let frontApp = NSWorkspace.shared.frontmostApplication {
            activeAppAtRecordingStart = (
                name: frontApp.localizedName ?? "Unknown",
                bundleId: frontApp.bundleIdentifier ?? "",
                processIdentifier: frontApp.processIdentifier
            )
        }
        recordingStartTime = Date()
        recordingDuration = 0
        sessionStatus = "Starting recording…"

        let wantsInterim = commandModeArmed && daemonStreamsInterimText && speculation.wantsInterimTranscripts()
        let response = await sendSocketCommandAsync("start", sessionID: sessionID, partials: wantsInterim)
        guard outputGate.sessionID == sessionID else { return false }
        guard let envelope = decodeSocketResponse(response ?? ""),
              envelope.status == "ok",
              envelope.state == "recording",
              envelope.sessionID == sessionID else {
            let message = "Couldn't start recording — is the speech engine running?"
            parakeetLog.error("start command failed: \(response ?? "nil", privacy: .public)")
            failSession(message)
            stopDaemon()
            return false
        }

        daemonState = .recording
        sessionStatus = "Recording…"
        settings.isRecording = true
        lastUserFacingError = nil
        settings.runtimeIssue = nil
        if commandModeArmed { speculation.begin(sessionID: sessionID) }
        return true
    }

    @MainActor
    func stopRecording() {
        guard daemonState == .recording, let sessionID = outputGate.sessionID else { return }
        recordingDuration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        daemonState = .transcribing
        sessionStatus = "Transcribing…"
        settings.isRecording = false
        armCompletionTimeout(sessionID: sessionID)
        sendSocketCommand("stop", sessionID: sessionID) { [weak self] response in
            DispatchQueue.main.async {
                guard let self, self.outputGate.sessionID == sessionID else { return }
                guard let envelope = self.decodeSocketResponse(response),
                       envelope.status == "ok", envelope.sessionID == sessionID else {
                    parakeetLog.error("stop command failed: \(response, privacy: .public)")
                    let message = "Couldn't confirm stop with the speech engine. Try recording again."
                    self.failSession(message)
                    self.stopDaemon()
                    return
                }
            }
        }
    }

    @MainActor
    func cancelRecording() {
        guard let sessionID = outputGate.sessionID else { return }
        commandModeArmed = false
        speculation.end(sessionID: sessionID)
        endInterimTranscripts(sessionID: sessionID)
        outputGate.close()
        completionTimeout?.cancel()
        recordingStartTime = nil
        activeAppAtRecordingStart = nil
        sessionStatus = "Recording cancelled"
        daemonState = .transcribing
        settings.isRecording = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            let cancelResponse = await self.sendSocketCommandAsync("cancel", sessionID: sessionID)
            guard let cancelEnvelope = self.decodeSocketResponse(cancelResponse ?? ""), cancelEnvelope.status == "ok" else {
                parakeetLog.error("cancel command failed: \(cancelResponse ?? "nil", privacy: .public)")
                self.stopDaemon()
                return
            }

            // Confirm the engine is back at idle before reusing it. Older engines omit `state`
            // from the cancel reply, so fall back to a status probe. Only restart if it is stuck.
            var engineState = cancelEnvelope.state
            if engineState == nil {
                let statusResponse = await self.sendSocketCommandAsync("status")
                engineState = self.decodeSocketResponse(statusResponse ?? "")?.state
            }
            guard self.daemonState == .transcribing, self.outputGate.sessionID == nil else { return }
            if engineState == "idle" {
                self.daemonState = .idle
                self.resetIdleTimer()
            } else {
                parakeetLog.warning("Engine state after cancel was \(engineState ?? "unknown", privacy: .public); restarting")
                try? await self.restartDaemon()
            }
        }
    }

    @MainActor
    func refreshDiagnostics() {
        let readiness = AppReadiness.current(settings: settings)
        lastDiagnosticsSummary = diagnosticSummary(readiness: readiness)
    }

    @MainActor
    private func resetIdleTimer() {
        idleShutdownTask?.cancel()
        idleShutdownTask = nil

        let timeoutMinutes = settings.idleTimeoutMinutes
        guard timeoutMinutes > 0 else { return }

        let task = DispatchWorkItem { [weak self] in
            guard let self = self, self.daemonState == .idle else { return }
            parakeetLog.info("Idle timeout reached (\(timeoutMinutes) min), stopping daemon to reclaim resources")
            self.stopDaemon()
        }
        idleShutdownTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(timeoutMinutes * 60), execute: task)
    }

    private struct SocketCommand: Encodable {
        let command: String
        var session_id: String?
        var partials: Bool?
    }

    private struct SocketCommandResult: Sendable {
        let response: String?
        let runtimeIssue: String?
    }

    private struct SocketResponseEnvelope: Decodable {
        let status: String
        let state: String?
        let sessionID: String?
        let protocolVersion: Int?

        enum CodingKeys: String, CodingKey {
            case status, state
            case sessionID = "session_id"
            case protocolVersion = "protocol_version"
        }
    }

    private func decodeSocketResponse(_ response: String) -> SocketResponseEnvelope? {
        guard let data = response.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SocketResponseEnvelope.self, from: data)
    }

    private func sendSocketCommand(_ command: String, sessionID: String? = nil, completion: (@Sendable (String) -> Void)? = nil) {
        Task { [weak self] in
            let response = await self?.sendSocketCommandAsync(command, sessionID: sessionID)
            completion?(response ?? "")
        }
    }

    private func sendSocketCommandAsync(_ command: String, sessionID: String? = nil, partials: Bool = false) async -> String? {
        let socketPath = settings.socketPath
        let result = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let timeout = timeval(tv_sec: 5, tv_usec: 0)
                let result = Self.sendSocketCommandSynchronously(
                    command,
                    socketPath: socketPath,
                    timeout: timeout,
                    sessionID: sessionID,
                    partials: partials
                )
                continuation.resume(returning: result)
            }
        }
        if let issue = result.runtimeIssue {
            publishRuntimeIssue(issue)
        }
        return result.response
    }

    private static func sendSocketCommandSynchronously(
        _ command: String,
        socketPath: String,
        timeout requestedTimeout: timeval,
        sessionID: String? = nil,
        partials: Bool = false
    ) -> SocketCommandResult {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            parakeetLog.error("Failed to create socket")
            return SocketCommandResult(response: nil, runtimeIssue: nil)
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
            parakeetLog.error("\(message, privacy: .public) Path: \(socketPath, privacy: .public)")
            return SocketCommandResult(response: nil, runtimeIssue: message)
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        var mutableAddr = addr
        let connectResult = withUnsafePointer(to: &mutableAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, addrLen)
            }
        }

        guard connectResult == 0 else {
            parakeetLog.error("Failed to connect to socket at \(socketPath, privacy: .public): \(errno)")
            return SocketCommandResult(response: nil, runtimeIssue: "Superkeet could not reach the speech engine. Try relaunching the app.")
        }

        let request = SocketCommand(command: command, session_id: sessionID, partials: partials ? true : nil)
        guard let jsonData = try? JSONEncoder().encode(request),
              var json = String(data: jsonData, encoding: .utf8) else {
            parakeetLog.error("Failed to encode socket command")
            return SocketCommandResult(response: nil, runtimeIssue: nil)
        }
        json.append("\n")

        let sentAllBytes = json.withCString { cstr in
            let byteCount = strlen(cstr)
            return send(fd, cstr, byteCount, 0) == byteCount
        }

        guard sentAllBytes else {
            parakeetLog.error("Failed to send socket command '\(command, privacy: .public)' to daemon")
            return SocketCommandResult(response: nil, runtimeIssue: nil)
        }

        var buffer = [UInt8](repeating: 0, count: 4096)
        var responseData = Data()
        while responseData.count < 65_536 {
            let bytesRead = recv(fd, &buffer, buffer.count, 0)
            if bytesRead == 0 { break }
            guard bytesRead > 0 else { return SocketCommandResult(response: nil, runtimeIssue: nil) }
            responseData.append(contentsOf: buffer.prefix(bytesRead))
            if responseData.contains(0x0A) { break }
        }
        return SocketCommandResult(response: String(data: responseData, encoding: .utf8), runtimeIssue: nil)
    }

    private static func unixSocketAddress(for socketPath: String) -> sockaddr_un? {
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

    @MainActor
    private func handleDaemonOutput(_ data: Data) {
        dispatchPrecondition(condition: .onQueue(.main))
        do {
            if data.isEmpty {
                try outputStream.finish()
                if outputGate.sessionID != nil { throw TranscriptProtocolError.incompleteMessage }
                return
            }
            for event in try outputStream.append(data) where outputGate.accepts(event) {
                switch event.kind {
                case .sessionStarted: break
                case .transcribing:
                    if daemonState == .recording {
                        recordingDuration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
                        armCompletionTimeout(sessionID: event.sessionID)
                    }
                    daemonState = .transcribing
                    settings.isRecording = false
                    sessionStatus = "Transcribing…"
                case .partial:
                    deliverInterim(event)
                case .complete:
                    guard ["ok", "partial", "empty", "error"].contains(event.status ?? ""), event.text != nil else {
                        throw TranscriptProtocolError.invalidMessage
                    }
                    completeSession(event)
                case .unrecognized(let type):
                    parakeetLog.info("Ignoring unrecognized transcript event type \(type, privacy: .public)")
                }
            }
        } catch {
            failSession(error.localizedDescription)
            stopDaemon()
        }
    }

    @MainActor
    private func completeSession(_ event: TranscriptEvent) {
        dispatchPrecondition(condition: .onQueue(.main))
        let raw = event.text ?? ""
        let delivery = CommandTranscriptDelivery.decide(
            event: event, commandMode: commandModeArmed,
            replacements: PhraseReplacementStore.shared.rules, bundleID: activeAppAtRecordingStart?.bundleId ?? ""
        )
        commandModeArmed = false
        switch delivery {
        case .command(let corrected):
            lastRawTranscription = raw
            lastTranscription = corrected
            canUndoTextChanges = false
            let earlyLaunch = speculation.take(sessionID: event.sessionID)
            AgentSessionController.shared.handleCommand(corrected, speculative: earlyLaunch)
            sessionStatus = "Working on it…"
            publishOutcome(.command)
            return finishSession()
        case .failure(let message):
            lastRawTranscription = raw
            lastTranscription = raw
            canUndoTextChanges = false
            return failSession(message)
        case .empty:
            sessionStatus = "No speech detected"
            publishOutcome(.noSpeech)
            return finishSession()
        case .dictation: break
        }
        let partial = event.isPartial && !raw.isEmpty
        if !raw.isEmpty { processTranscription(raw, isPartial: partial) }
        if partial {
            let detail = event.message ?? "\(event.failedSegments ?? 0) failed segments, \(event.droppedSamples ?? 0) dropped samples"
            sessionStatus = "Partial transcript — \(detail)"
            lastUserFacingError = sessionStatus
            settings.runtimeIssue = sessionStatus
        } else if event.status == "error" || (event.isPartial && raw.isEmpty) {
            return failSession(event.message ?? "Transcription failed.")
        } else if raw.isEmpty {
            sessionStatus = "No speech detected"
            publishOutcome(.noSpeech)
        } else {
            sessionStatus = "Transcription complete"
        }
        finishSession()
    }

    @MainActor
    private func publishOutcome(_ outcome: TranscriptOutcome) {
        lastOutcome = TranscriptOutcomeEvent(outcome)
    }

    @MainActor
    private func processTranscription(_ text: String, isPartial: Bool) {
        let appInfo = activeAppAtRecordingStart ?? (name: "Unknown", bundleId: "", processIdentifier: nil)
        let processedText = TranscriptTextProcessor.process(
            text, removeFillers: settings.fillerWordRemovalEnabled,
            replacements: PhraseReplacementStore.shared.rules, bundleID: appInfo.bundleId,
            spokenCommands: settings.spokenCorrectionsEnabled
        )
        lastRawTranscription = text
        lastTranscription = processedText
        canUndoTextChanges = text != processedText

        let duration = recordingDuration

        let record = TranscriptionRecord(
            text: processedText,
            durationSeconds: duration,
            activeAppName: appInfo.name,
            activeAppBundleId: appInfo.bundleId,
            rawText: text,
            isPartial: isPartial
        )

        UsageStatsStore.shared.record(wordCount: record.wordCount, durationSeconds: duration)

        let outputDecision = OutputRouting.decision(
            keepOnClipboardAfterPaste: settings.clipboardCopyEnabled,
            autoPasteEnabled: settings.autoPasteEnabled,
            saveHistoryEnabled: settings.saveHistoryEnabled
        )

        if outputDecision.shouldSaveHistory {
            HistoryStore.shared.addRecord(record)
        }

        if outputDecision.shouldCopyToClipboard && !processedText.isEmpty {
            PasteService.shared.deliverText(
                processedText,
                decision: outputDecision,
                targetProcessIdentifier: appInfo.processIdentifier,
                onDelivered: { [weak self] delivery in
                    Task { @MainActor [weak self] in
                        self?.publishOutcome(.forDictation(delivery: delivery, isPartial: isPartial))
                    }
                }
            )
        } else if processedText.isEmpty {
            // The take was only filler words; nothing was worth delivering.
            publishOutcome(.noSpeech)
        } else {
            // Clipboard and paste are both off; the take finished but nothing left the app.
            publishOutcome(isPartial ? .partial : .done)
        }
    }

    @MainActor
    private func finishSession() {
        completionTimeout?.cancel()
        completionTimeout = nil
        endSpeculation()
        if let sessionID = outputGate.sessionID { endInterimTranscripts(sessionID: sessionID) }
        outputGate.close()
        recordingStartTime = nil
        activeAppAtRecordingStart = nil
        settings.isRecording = false
        if daemonState == .recording || daemonState == .transcribing { daemonState = .idle }
        resetIdleTimer()
    }

    @MainActor
    private func failSession(_ message: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        commandModeArmed = false
        sessionStatus = "Transcription failed"
        lastUserFacingError = message
        settings.runtimeIssue = message
        if outputGate.sessionID != nil { publishOutcome(.failed) }
        finishSession()
    }

    /// Inference on Apple Silicon runs well under real time, so a healthy engine finishes in a
    /// fraction of the recording length. Scale the deadline with the take so a stuck engine is
    /// detected in seconds for short dictation instead of holding recording hostage for minutes.
    static func completionTimeout(forRecordingDuration duration: TimeInterval) -> TimeInterval {
        min(max(20, duration * 2), 300)
    }

    @MainActor
    private func armCompletionTimeout(sessionID: String) {
        completionTimeout?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.outputGate.sessionID == sessionID else { return }
            self.failSession("Transcription timed out. The speech engine will restart.")
            self.stopDaemon()
        }
        completionTimeout = task
        let deadline = Self.completionTimeout(forRecordingDuration: recordingDuration)
        DispatchQueue.main.asyncAfter(deadline: .now() + deadline, execute: task)
    }

    func undoLastTextChanges() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard canUndoTextChanges else { return }
        lastTranscription = lastRawTranscription
        canUndoTextChanges = false
        PasteService.shared.copyToClipboard(lastTranscription)
        sessionStatus = "Original transcript restored and copied"
    }

    func cleanupAndWait() async {
        await stopDaemonAndWait()
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
            try Data("ok".utf8).write(to: probeURL)
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
                let diagnostics = await MainActor.run { self.recentStderrExcerpt() }
                await publishStartupFailure(detail, diagnostics: diagnostics)
                throw NSError(domain: "ParakeetService", code: 5, userInfo: [
                    NSLocalizedDescriptionKey: detail
                ])
            }

            await MainActor.run {
                self.startupStatusDetail = self.derivedStartupStatus()
            }

            try await Task.sleep(nanoseconds: Self.startupPollIntervalNanoseconds)
        }

        let detail = "Parakeet did not become ready within \(Self.startupTimeoutNanoseconds / 1_000_000_000) seconds."
        let diagnostics = await MainActor.run { self.recentStderrExcerpt() }
        await publishStartupFailure(detail, diagnostics: diagnostics)
        throw NSError(domain: "ParakeetService", code: 6, userInfo: [
            NSLocalizedDescriptionKey: detail
        ])
    }

    private func probeSocketReadiness() async throws -> Bool {
        let timeout = timeval(tv_sec: 0, tv_usec: 300_000)
        let response = Self.sendSocketCommandSynchronously(
            "status",
            socketPath: settings.socketPath,
            timeout: timeout
        ).response
        guard let envelope = decodeSocketResponse(response ?? ""), envelope.status == "ok" else { return false }
        guard let version = envelope.protocolVersion, Self.supportedProtocolVersions.contains(version) else {
            throw TranscriptProtocolError.invalidMessage
        }
        await MainActor.run { self.daemonProtocolVersion = version }
        parakeetLog.info("Speech engine ready with protocol \(version)")
        return true
    }

    @MainActor
    private func publishStartupFailure(_ detail: String, diagnostics: String?) async {
        let message = diagnostics.map { "\(detail)\n\n\($0)" } ?? detail
        lastUserFacingError = message
        lastDiagnosticsSummary = diagnostics
        startupStatusDetail = "Startup failed"
        settings.runtimeIssue = message
    }

    @MainActor
    private func appendStderr(_ text: String) {
        stderrBuffer += text
        let lines = stderrBuffer.components(separatedBy: .newlines)
        if lines.count > 25 {
            stderrBuffer = lines.suffix(25).joined(separator: "\n")
        }
        startupStatusDetail = derivedStartupStatus()
    }

    @MainActor
    private func recentStderrExcerpt() -> String? {
        let trimmed = stderrBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return "Parakeet stderr:\n\(trimmed)"
    }

    @MainActor
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
        parakeetLog.info("\(message, privacy: .public)")
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
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(bytes: bytes, encoding: .utf8)
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
        - Speech model: \(diagnostics.modelInstalled ? "installed" : "not downloaded") at \(settings.effectiveModelDirectory)
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
