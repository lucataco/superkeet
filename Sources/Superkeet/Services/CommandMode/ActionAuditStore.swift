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
    var grounding: ActionGroundingDecision?
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
    private var entryCount = 0

    init(
        fileURL: URL = AppPaths.applicationSupportDirectory.appendingPathComponent("action-audit.log"),
        maxEntries: Int = ActionAuditStore.defaultMaxEntries,
        maxBytes: Int = ActionAuditStore.defaultMaxBytes
    ) {
        self.fileURL = fileURL
        self.maxEntries = max(1, maxEntries)
        self.maxBytes = max(1, maxBytes)
        self.entryCount = Self.lineCount(at: fileURL)
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

    func record(
        serverName: String,
        toolName: String,
        risk: ActionToolRisk,
        argumentsJSON: String,
        outcome: String,
        detail: String? = nil,
        grounding: ActionGroundingDecision? = nil,
        redactionContext: ActionRedactor.Context = .toolArguments
    ) {
        let context: ActionRedactor.Context = grounding == nil ? redactionContext : .groundingUI
        let entry = ActionAuditEntry(
            timestamp: Date(),
            serverName: serverName,
            toolName: toolName,
            risk: risk.rawValue,
            arguments: ActionRedactor.redact(argumentsJSON, context: context),
            outcome: outcome,
            detail: context == .groundingUI ? nil : detail.map { ActionResultText.truncate(ActionRedactor.redactText($0), limit: 500) },
            grounding: grounding
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
            entryCount += 1
        } catch {
            log.error("Failed to append action audit entry: \(error.localizedDescription)")
        }
        pruneIfNeededLocked()
    }

    private func pruneIfNeededLocked() {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes?[.size] as? Int) ?? 0
        guard entryCount > maxEntries || size > maxBytes else { return }

        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let lines = contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        entryCount = lines.count

        var totalBytes = lines.reduce(0) { $0 + $1.utf8.count + 1 }
        var start = 0
        while lines.count - start > 1, totalBytes > maxBytes || lines.count - start > maxEntries {
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
