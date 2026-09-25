import Foundation

enum LoginShellPath {
    static let fallback = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    static let marker = "__SUPERKEET_PATH__"
    static let defaultTimeout: TimeInterval = 5

    private static let defaultCommand = "printf '\(marker)%s' \"$PATH\""
    private static let cache = Cache()

    static func current() async -> String {
        if let cached = cache.value { return cached }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let output = await runLoginShell(shell: shell)
        let resolved = merged(shellOutput: output, fallback: fallback)
        cache.value = resolved
        return resolved
    }

    static func merged(shellOutput: String?, fallback: String) -> String {
        let trimmed = shellOutput?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var entries = trimmed.split(separator: ":").map(String.init).filter { !$0.isEmpty }
        for entry in fallback.split(separator: ":").map(String.init) where !entries.contains(entry) {
            entries.append(entry)
        }
        return entries.joined(separator: ":")
    }

    static func extractPath(from output: String) -> String? {
        guard let range = output.range(of: marker) else { return nil }
        let remainder = output[range.upperBound...]
        return remainder.components(separatedBy: .newlines).first
    }

    static func runLoginShell(
        shell: String,
        timeout: TimeInterval = defaultTimeout,
        command: String = defaultCommand
    ) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", command]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        return await withCheckedContinuation { continuation in
            let completion = Completion(continuation: continuation, stdout: stdout, stderr: stderr)

            stderr.fileHandleForReading.readabilityHandler = { handle in
                if handle.availableData.isEmpty { handle.readabilityHandler = nil }
            }

            process.terminationHandler = { proc in
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                guard proc.terminationStatus == 0,
                      let text = String(data: data, encoding: .utf8) else {
                    completion.finish(nil)
                    return
                }
                completion.finish(extractPath(from: text))
            }

            do {
                try process.run()
            } catch {
                completion.finish(nil)
                return
            }

            let deadline = DispatchTime.now() + timeout
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) {
                guard process.isRunning else { return }
                process.terminate()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                    completion.finish(nil)
                }
            }
        }
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?

        var value: String? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); defer { lock.unlock() }; stored = newValue }
        }
    }

    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private let continuation: CheckedContinuation<String?, Never>
        private let stdout: Pipe
        private let stderr: Pipe
        private var claimed = false

        init(continuation: CheckedContinuation<String?, Never>, stdout: Pipe, stderr: Pipe) {
            self.continuation = continuation
            self.stdout = stdout
            self.stderr = stderr
        }

        func finish(_ result: String?) {
            lock.lock()
            guard !claimed else {
                lock.unlock()
                return
            }
            claimed = true
            lock.unlock()

            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            continuation.resume(returning: result)
        }
    }
}
