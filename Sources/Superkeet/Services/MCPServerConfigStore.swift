import Foundation
import os.log

final class MCPServerConfigStore: ObservableObject, @unchecked Sendable {
    static let shared = MCPServerConfigStore()

    @Published private(set) var servers: [MCPServerConfiguration] = []
    @Published private(set) var errorMessage: String?

    private let fileURL: URL
    private let secrets: MCPSecretStoring
    private let log = Logger(subsystem: "com.superkeet.app", category: "MCPServerConfigStore")

    init(
        fileURL: URL = AppPaths.applicationSupportDirectory.appendingPathComponent("mcp-servers.json"),
        secrets: MCPSecretStoring = KeychainMCPSecretStore()
    ) {
        self.fileURL = fileURL
        self.secrets = secrets
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
            servers = document.configurations().map(mergingSecrets)
            errorMessage = nil
        } catch {
            servers = []
            errorMessage = "Could not read MCP servers: \(error.localizedDescription)"
            log.error("Failed to load MCP servers: \(error.localizedDescription)")
        }
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
