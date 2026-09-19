import Foundation
import os.log

final class MCPServerConfigStore: ObservableObject, @unchecked Sendable {
    static let shared = MCPServerConfigStore()

    @Published private(set) var servers: [MCPServerConfiguration] = []
    @Published private(set) var errorMessage: String?

    private let fileURL: URL
    private let secrets: MCPSecretStoring
    private let migrationWriter: (Data, URL) throws -> Void
    private let log = Logger(subsystem: "com.superkeet.app", category: "MCPServerConfigStore")

    init(
        fileURL: URL = AppPaths.applicationSupportDirectory.appendingPathComponent("mcp-servers.json"),
        secrets: MCPSecretStoring = KeychainMCPSecretStore(),
        migrationWriter: @escaping (Data, URL) throws -> Void = { data, url in try data.write(to: url, options: .atomic) }
    ) {
        self.fileURL = fileURL
        self.secrets = secrets
        self.migrationWriter = migrationWriter
        load()
    }

    var enabledServers: [MCPServerConfiguration] {
        servers.filter(\.enabled)
    }

    static func validate(_ servers: [MCPServerConfiguration]) throws {
        var seen: Set<String> = []
        for server in servers {
            let name = server.trimmedName
            guard !name.isEmpty else { throw MCPServerConfigError.emptyName }
            guard !server.trimmedCommand.isEmpty else { throw MCPServerConfigError.emptyCommand }
            guard seen.insert(name.lowercased()).inserted else {
                throw MCPServerConfigError.duplicateName(name)
            }
        }
    }

    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            servers = MCPDefaultServers.all
            errorMessage = nil
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let document = try JSONDecoder().decode(MCPServersDocument.self, from: data)
            var loaded = document.configurations().map(mergingSecrets)
            if let index = loaded.firstIndex(where: MCPDefaultServers.needsChromeAutoConnectMigration) {
                do {
                    if let migrated = try Self.chromeAutoConnectMigration(in: data) {
                        try migrationWriter(migrated, fileURL)
                        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
                        loaded[index].args = MCPDefaultServers.chromeArguments
                    }
                } catch {
                    // A failed migration must not discard an otherwise readable
                    // configuration or publish settings that were not persisted.
                    servers = loaded
                    errorMessage = "Could not update the default Chrome connection: \(error.localizedDescription)"
                    log.error("Chrome connection migration failed: \(error.localizedDescription)")
                    return
                }
            }
            servers = loaded
            errorMessage = nil
        } catch {
            servers = []
            errorMessage = "Could not read MCP servers: \(error.localizedDescription)"
            log.error("Failed to load MCP servers: \(error.localizedDescription)")
        }
    }

    private static func chromeAutoConnectMigration(in data: Data) throws -> Data? {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var entries = root["mcpServers"] as? [String: Any],
              var chrome = entries["chrome-devtools"] as? [String: Any],
              Set(chrome.keys).isSubset(of: ["command", "args", "env", "enabled", "transport"]),
              chrome["transport"] == nil || chrome["transport"] is NSNull || chrome["transport"] as? String == "stdio" else { return nil }
        // Patch only the known entry's arguments in the original JSON, retaining
        // all other entries and unknown top-level fields. Do not re-save secrets.
        chrome["args"] = MCPDefaultServers.chromeArguments
        entries["chrome-devtools"] = chrome
        root["mcpServers"] = entries
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    private func mergingSecrets(_ server: MCPServerConfiguration) -> MCPServerConfiguration {
        let stored = secrets.secretEnvironment(for: server.trimmedName)
        guard !stored.isEmpty else { return server }
        var merged = server
        merged.env.merge(stored) { _, secret in secret }
        return merged
    }

    var missingDefaultServerCount: Int {
        let existing = Set(servers.map { $0.trimmedName.lowercased() })
        return MCPDefaultServers.all.filter { !existing.contains($0.trimmedName.lowercased()) }.count
    }

    func addDefaultServers() {
        let existing = Set(servers.map { $0.trimmedName.lowercased() })
        let missing = MCPDefaultServers.all.filter { !existing.contains($0.trimmedName.lowercased()) }
        guard !missing.isEmpty else { return }
        do {
            try save(servers + missing)
        } catch {
            record(error)
        }
    }

    func save(_ updated: [MCPServerConfiguration]) throws {
        dispatchPrecondition(condition: .onQueue(.main))
        try Self.validate(updated)
        let sorted = updated.sorted {
            $0.trimmedName.localizedCaseInsensitiveCompare($1.trimmedName) == .orderedAscending
        }
        let sanitized = sorted.map(Self.withoutSecrets)
        let document = MCPServersDocument.document(from: sanitized)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(document).write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        persistSecrets(for: sorted)
        servers = sorted
        errorMessage = nil
    }

    static func withoutSecrets(_ server: MCPServerConfiguration) -> MCPServerConfiguration {
        var copy = server
        copy.env = server.env.filter { !SensitiveDataPolicy.isSensitiveKey($0.key) }
        return copy
    }

    private func persistSecrets(for servers: [MCPServerConfiguration]) {
        for server in servers {
            let sensitive = server.env.filter { SensitiveDataPolicy.isSensitiveKey($0.key) }
            if sensitive.isEmpty {
                secrets.removeSecretEnvironment(for: server.trimmedName)
            } else {
                secrets.setSecretEnvironment(sensitive, for: server.trimmedName)
            }
        }
    }

    func add(_ server: MCPServerConfiguration) {
        do {
            try save(servers + [server])
        } catch {
            record(error)
        }
    }

    func update(_ server: MCPServerConfiguration) {
        let oldName = servers.first(where: { $0.id == server.id })?.trimmedName
        do {
            try save(servers.map { $0.id == server.id ? server : $0 })
            if let oldName, oldName != server.trimmedName {
                secrets.removeSecretEnvironment(for: oldName)
            }
        } catch {
            record(error)
        }
    }

    func remove(id: UUID) {
        guard let removed = servers.first(where: { $0.id == id }) else { return }
        do {
            try save(servers.filter { $0.id != id })
            secrets.removeSecretEnvironment(for: removed.trimmedName)
        } catch {
            record(error)
        }
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        guard let server = servers.first(where: { $0.id == id }) else { return }
        var updated = server
        updated.enabled = enabled
        update(updated)
    }

    func clearError() {
        errorMessage = nil
    }

    private func record(_ error: Error) {
        errorMessage = error.localizedDescription
        log.error("Failed to save MCP servers: \(error.localizedDescription)")
    }
}
