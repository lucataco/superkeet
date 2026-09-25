import Foundation
import os.log

struct ActionAuditEntry: Codable, Equatable {
    let timestamp: Date
    let serverName: String
    let toolName: String
    let risk: String
    let arguments: String
    let outcome: String
    let detail: String?
    /// Milliseconds since the user's command began (the recording start when the interim text
    /// was flowing, otherwise the run start). Nil for entries written outside a command.
    var sinceCommandMs: Int?
    /// Milliseconds the tool call itself took. Nil for decisions and early launches.
    var durationMs: Int?
}

final class ActionAuditStore: @unchecked Sendable {
    static let shared = ActionAuditStore()

    static let defaultMaxEntries = 2_000
    static let defaultMaxBytes = 1_000_000

    private let fileURL: URL
    private let maxEntries: Int
    private let maxBytes: Int
    private let log = Logger(subsystem: "com.superkeet.app", category: "ActionAuditStore")
    private let lock = NSLock()
    /// Counted lazily on the first append so creating the store (which happens at app launch even
    /// with Actions Mode off) never reads the log file.
    private var entryCount: Int?
    private var timelineStart: Date?

    init(
        fileURL: URL = AppPaths.applicationSupportDirectory.appendingPathComponent("action-audit.log"),
        maxEntries: Int = ActionAuditStore.defaultMaxEntries,
        maxBytes: Int = ActionAuditStore.defaultMaxBytes
    ) {
        self.fileURL = fileURL
        self.maxEntries = max(1, maxEntries)
        self.maxBytes = max(1, maxBytes)
    }

    var logFileURL: URL { fileURL }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL)
        entryCount = 0
    }

    private static func lineCount(at url: URL) -> Int {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return contents.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    /// Marks when the user's command began so later entries carry `sinceCommandMs`. The recording
    /// start marks with `replacing: true`; the run start uses `replacing: false` so it keeps the
    /// earlier mark when one exists and only fills in when nothing was listening.
    func beginTimeline(at date: Date = Date(), replacing: Bool = true) {
        lock.lock()
        defer { lock.unlock() }
        if replacing || timelineStart == nil { timelineStart = date }
    }

    func endTimeline() {
        lock.lock()
        defer { lock.unlock() }
        timelineStart = nil
    }

    func record(
        serverName: String,
        toolName: String,
        risk: ActionToolRisk,
        argumentsJSON: String,
        outcome: String,
        detail: String? = nil,
        durationMs: Int? = nil
    ) {
        let now = Date()
        lock.lock()
        let sinceCommand = timelineStart.map { max(0, Int(now.timeIntervalSince($0) * 1_000)) }
        lock.unlock()
        let entry = ActionAuditEntry(
            timestamp: now,
            serverName: serverName,
            toolName: toolName,
            risk: risk.rawValue,
            arguments: ActionRedactor.redact(argumentsJSON),
            outcome: outcome,
            detail: detail.map { ActionResultText.truncate(ActionRedactor.redactText($0), limit: 500) },
            sinceCommandMs: sinceCommand,
            durationMs: durationMs
        )
        append(entry)
    }

    func entries() -> [ActionAuditEntry] {
        lock.lock()
        defer { lock.unlock() }
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(ActionAuditEntry.self, from: data)
            }
    }

    private func append(_ entry: ActionAuditEntry) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)

        lock.lock()
        defer { lock.unlock() }
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                _ = try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try line.write(to: fileURL, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            }
            if let known = entryCount {
                entryCount = known + 1
            } else {
                // First append this launch: the file now includes the line we just wrote.
                entryCount = Self.lineCount(at: fileURL)
            }
        } catch {
            log.error("Failed to append action audit entry: \(error.localizedDescription)")
        }
        pruneIfNeededLocked()
    }

    /// Fraction of a limit to keep after pruning, leaving headroom before the next rewrite.
    static let pruneRetainFraction = 0.75

    static func pruneTarget(for limit: Int) -> Int {
        max(1, Int(Double(limit) * pruneRetainFraction))
    }

    private func pruneIfNeededLocked() {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes?[.size] as? Int) ?? 0
        guard (entryCount ?? 0) > maxEntries || size > maxBytes else { return }

        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let lines = contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        entryCount = lines.count

        // Trim to below the limits, not just under them. Stopping right at the limit made every
        // following append go over again and rewrite the whole (~1 MB) file.
        let targetEntries = Self.pruneTarget(for: maxEntries)
        let targetBytes = Self.pruneTarget(for: maxBytes)
        var totalBytes = lines.reduce(0) { $0 + $1.utf8.count + 1 }
        var start = 0
        while lines.count - start > 1, totalBytes > targetBytes || lines.count - start > targetEntries {
            totalBytes -= lines[start].utf8.count + 1
            start += 1
        }

        guard start > 0 else { return }
        let kept = lines[start...].joined(separator: "\n") + "\n"
        do {
            try kept.write(to: fileURL, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            entryCount = lines.count - start
        } catch {
            log.error("Failed to prune action audit log: \(error.localizedDescription)")
        }
    }
}
