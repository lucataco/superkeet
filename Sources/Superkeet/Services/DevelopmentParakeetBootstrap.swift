import Foundation
import os.log

private let developmentBootstrapLog = Logger(subsystem: "com.superkeet.app", category: "DevelopmentParakeetBootstrap")

enum DevelopmentParakeetBootstrap {
    static func ensureAvailable(settings: AppSettings = .shared) async throws -> String {
        guard settings.canBootstrapDevelopmentParakeet else {
            throw DevelopmentParakeetBootstrapError.message(settings.missingParakeetBinaryMessage)
        }

        let selection = try DevelopmentEngineLocator.select()
        guard case .source(let sourceDirectory, let needsClone) = selection else { return selection.binaryURL.path }

        guard let cargoPath = executablePath(named: "cargo") else {
            throw DevelopmentParakeetBootstrapError.message(
                "Superkeet could not build parakeet-cli for swift run because Rust/Cargo is not available on PATH. Install Rust, then try swift run again, or set PARAKEET_CLI_PATH to an existing parakeet binary."
            )
        }

        if needsClone {
            guard let git = executablePath(named: "git") else {
                throw DevelopmentParakeetBootstrapError.message("Install git to download the speech engine sources.")
            }
            try FileManager.default.createDirectory(at: sourceDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await runProcess(executablePath: git, arguments: ["clone", "--depth", "1", "--branch", DevelopmentEngineLocator.repositoryRef, DevelopmentEngineLocator.repositoryURL, sourceDirectory.path])
        }

        developmentBootstrapLog.info("Building development parakeet binary from \(sourceDirectory.path, privacy: .public)")
        try await runProcess(
            executablePath: cargoPath,
            arguments: [
                "build",
                "--release",
                "--locked",
                "--bin",
                "parakeet",
                "--manifest-path",
                sourceDirectory.appendingPathComponent("Cargo.toml").path
            ]
        )

        let builtPath = selection.binaryURL.path
        guard FileManager.default.isExecutableFile(atPath: builtPath) else {
            throw DevelopmentParakeetBootstrapError.message(
                "Superkeet built parakeet-cli, but could not find the parakeet binary at \(builtPath). Set PARAKEET_CLI_PATH to the built binary and try again."
            )
        }

        return builtPath
    }

    private static func executablePath(named name: String) -> String? {
        let environment = ProcessInfo.processInfo.environment
        let pathDirectories = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let candidates = pathDirectories + [
            "\(NSHomeDirectory())/.cargo/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin"
        ]

        return candidates
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name).path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func runProcess(executablePath: String, arguments: [String]) async throws {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments

            let outputPipe = Pipe()
            let output = BootstrapProcessOutput()
            process.standardOutput = outputPipe
            process.standardError = outputPipe
            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty {
                    output.append(data)
                }
            }

            try process.run()
            process.waitUntilExit()
            outputPipe.fileHandleForReading.readabilityHandler = nil

            guard process.terminationStatus == 0 else {
                let command = ([executablePath] + arguments).joined(separator: " ")
                let detail = output.excerpt.map { "\n\n\($0)" } ?? ""
                throw DevelopmentParakeetBootstrapError.message(
                    "Failed to run `\(command)` while preparing parakeet-cli for swift run.\(detail)"
                )
            }
        }.value
    }
}

enum DevelopmentParakeetBootstrapError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text):
            return text
        }
    }
}

private final class BootstrapProcessOutput {
    private let lock = NSLock()
    private var data = Data()

    func append(_ newData: Data) {
        lock.lock()
        data.append(newData)
        if data.count > 16_384 {
            data.removeSubrange(data.startIndex..<(data.endIndex - 16_384))
        }
        lock.unlock()
    }

    var excerpt: String? {
        lock.lock()
        defer { lock.unlock() }
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }
}
