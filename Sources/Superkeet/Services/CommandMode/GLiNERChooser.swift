import Foundation
import Darwin
import os.log

/// One resident, offline-only model process. Requests are serialized; a timeout or
/// cancellation destroys the transport so a late reply cannot answer a new request.
actor GLiNERChooser: ActionChoosing {
    struct Timing: Sendable {
        var coldSeconds: Double = 60
        var warmSeconds: Double = 2
        var idleSeconds: Double = 600
        var backoffSeconds: Double = 5
    }
    static let shared = GLiNERChooser()
    static let model = "lucataco/gliner2.5-cua-grounder-macos-v1"
    static var defaultPython: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Superkeet/Grounder/venv/bin/python3").path
    }

    private let python: String
    private let script: String?
    private let device: String
    private let timing: Timing
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var busy = false
    private var idleTask: Task<Void, Never>?
    private var retryAfter = Date.distantPast
    private var generation = UUID()
    private let log = Logger(subsystem: "com.superkeet.app", category: "GLiNER")

    var isLoaded: Bool { process?.isRunning == true && !busy }

    init(python: String = GLiNERChooser.defaultPython, script: String? = nil, device: String = "mps", timing: Timing = Timing()) {
        self.python = python
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("gliner/serve_grounder.py").path
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../scripts/gliner/serve_grounder.py").standardized.path
        self.script = script ?? (bundled.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }) ?? source
        self.device = device
        self.timing = timing
    }

    func prepare() async throws {
        try Task.checkCancellation()
        if process?.isRunning == true && !busy { return }
        try await warm()
    }

    func warm() async throws {
        let request = ChoiceRequest(goal: "Do not act.", captureID: "warmup", regions: [], history: [],
                                    candidates: ActionCandidate.reserved.map { .init(id: $0.id, description: $0.description) })
        _ = try await choose(request)
    }

    func stop() {
        generation = UUID()
        idleTask?.cancel()
        idleTask = nil
        if let process, process.isRunning {
            process.terminate()
            Task.detached {
                try? await Task.sleep(for: .seconds(1))
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
        }
        try? input?.fileHandleForWriting.close()
        try? output?.fileHandleForReading.close()
        process = nil
        input = nil
        output = nil
    }

    func shutdown() async {
        let child = process
        stop()
        for _ in 0..<20 {
            guard child?.isRunning == true else { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
        if let child, child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
    }

    private func unloadIfIdle(generation: UUID) {
        guard !busy, generation == self.generation else { return }
        stop()
    }

    func choose(_ request: ChoiceRequest) async throws -> ChoiceResponse {
        guard !busy else { throw ActionChoiceError.invalid("grounder is busy") }
        let data = try request.encoded() + Data([10])
        busy = true
        idleTask?.cancel()
        defer { busy = false }
        do {
            try Task.checkCancellation()
            let cold = process?.isRunning != true
            if cold { try start() }
            guard let input, let output else { throw ActionChoiceError.invalid("grounder did not start") }
            let deadline = ContinuousClock.now.advanced(by: .seconds(cold ? timing.coldSeconds : timing.warmSeconds))
            let generation = self.generation
            try await write(data, to: input.fileHandleForWriting.fileDescriptor, deadline: deadline, generation: generation)
            let reply = try await read(from: output.fileHandleForReading.fileDescriptor, deadline: deadline, generation: generation)
            let response = try ChoiceResponse.decode(reply)
            guard response.model == Self.model else { throw ActionChoiceError.invalid("unexpected grounder model") }
            idleTask = Task { [weak self, timing] in
                do { try await Task.sleep(for: .seconds(timing.idleSeconds)) } catch { return }
                await self?.unloadIfIdle(generation: generation)
            }
            log.info("Grounder answered (cold: \(cold, privacy: .public))")
            return response
        } catch {
            stop()
            retryAfter = Date().addingTimeInterval(timing.backoffSeconds)
            throw error
        }
    }

    private func start() throws {
        guard Date() >= retryAfter else { throw ActionChoiceError.invalid("grounder is restarting; try again shortly") }
        stop()
        guard FileManager.default.isExecutableFile(atPath: python), let script,
              FileManager.default.fileExists(atPath: script) else {
            throw ActionChoiceError.invalid("install the local grounder runtime with scripts/install_grounder.sh")
        }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: python)
        // Importing bundled scripts must not create __pycache__ inside the signed app.
        process.arguments = ["-B", "-u", script, "--jsonl", "--device", device]
        var environment = ProcessInfo.processInfo.environment
        environment["SUPERKEET_GLINER_OFFLINE"] = "1"
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TOKENIZERS_PARALLELISM"] = "false"
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        for descriptor in [input.fileHandleForWriting.fileDescriptor, output.fileHandleForReading.fileDescriptor] {
            _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
            _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        }
        self.process = process
        self.input = input
        self.output = output
    }

    private func waitForIO(until deadline: ContinuousClock.Instant, generation: UUID) async throws {
        try Task.checkCancellation()
        guard generation == self.generation else { throw ActionExecutionError.cancelled }
        guard ContinuousClock.now < deadline else { throw ActionExecutionError.timedOut }
        guard process?.isRunning == true else { throw ActionChoiceError.invalid("grounder process exited") }
        try await Task.sleep(for: .milliseconds(10))
        guard generation == self.generation else { throw ActionExecutionError.cancelled }
    }

    private func write(_ data: Data, to descriptor: Int32, deadline: ContinuousClock.Instant, generation: UUID) async throws {
        var offset = 0
        while offset < data.count {
            try await waitForIO(until: deadline, generation: generation)
            let count = data.withUnsafeBytes { bytes in
                Darwin.write(descriptor, bytes.baseAddress?.advanced(by: offset), data.count - offset)
            }
            if count > 0 { offset += count } else if errno != EAGAIN && errno != EINTR {
                throw ActionChoiceError.invalid("grounder input closed")
            }
        }
    }

    private func read(from descriptor: Int32, deadline: ContinuousClock.Instant, generation: UUID) async throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            try await waitForIO(until: deadline, generation: generation)
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                result.append(contentsOf: buffer.prefix(count))
                guard result.count <= ChoiceRequest.maximumBytes else { throw ActionChoiceError.invalid("oversized grounder reply") }
                if let newline = result.firstIndex(of: 10) {
                    guard newline == result.count - 1 else { throw ActionChoiceError.invalid("unsolicited grounder reply") }
                    return result.dropLast()
                }
            } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                throw ActionChoiceError.invalid("grounder output closed")
            }
        }
    }
}
