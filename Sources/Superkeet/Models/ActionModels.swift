import Foundation

enum MCPTransportKind: String, Codable, CaseIterable, Identifiable {
    case stdio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stdio: return "Standard I/O (local process)"
        }
    }
}

struct MCPServerConfiguration: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var name: String
    var command: String
    var args: [String]
    var env: [String: String]
    var enabled: Bool
    var transport: MCPTransportKind

    init(
        id: UUID = UUID(),
        name: String,
        command: String,
        args: [String] = [],
        env: [String: String] = [:],
        enabled: Bool = true,
        transport: MCPTransportKind = .stdio
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.args = args
        self.env = env
        self.enabled = enabled
        self.transport = transport
    }

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedCommand: String {
        command.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isRunnable: Bool {
        !trimmedName.isEmpty && !trimmedCommand.isEmpty
    }

    var commandSummary: String {
        ([trimmedCommand] + args).joined(separator: " ")
    }
}

enum MCPServerConfigError: LocalizedError, Equatable {
    case emptyName
    case emptyCommand
    case duplicateName(String)

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Give the MCP server a name."
        case .emptyCommand:
            return "Provide the command that launches the MCP server (for example, npx)."
        case .duplicateName(let name):
            return "An MCP server named '\(name)' already exists."
        }
    }
}

struct MCPToolAnnotations: Equatable {
    var readOnlyHint: Bool?
    var destructiveHint: Bool?
    var idempotentHint: Bool?
    var openWorldHint: Bool?

    init(
        readOnlyHint: Bool? = nil,
        destructiveHint: Bool? = nil,
        idempotentHint: Bool? = nil,
        openWorldHint: Bool? = nil
    ) {
        self.readOnlyHint = readOnlyHint
        self.destructiveHint = destructiveHint
        self.idempotentHint = idempotentHint
        self.openWorldHint = openWorldHint
    }

    var hasBehaviorHint: Bool {
        readOnlyHint != nil || destructiveHint != nil
    }
}

enum MCPToolRiskClassifier {
    private static let observationalPrefixes = [
        "list_", "get_", "read_", "describe_", "inspect_", "search_", "find_", "fetch_", "snapshot"
    ]

    private static let observationalNames: Set<String> = [
        "list_apps", "get_app_state", "take_snapshot", "list_pages", "list_console_messages",
        "list_network_requests", "list_resources", "list_tools", "list_prompts"
    ]

    static func risk(for annotations: MCPToolAnnotations, name: String = "") -> ActionToolRisk {
        if annotations.readOnlyHint == true { return .readOnly }
        if annotations.destructiveHint == true { return .destructive }
        if !annotations.hasBehaviorHint, isObservationName(name) { return .readOnly }
        return .mutating
    }

    static func isObservationName(_ name: String) -> Bool {
        let normalized = name.lowercased()
        if observationalNames.contains(normalized) { return true }
        return observationalPrefixes.contains { normalized.hasPrefix($0) }
    }
}

enum MCPDefaultServers {
    static let legacyChromeArguments = ["-y", "chrome-devtools-mcp@latest"]
    static let chromeArguments = legacyChromeArguments + ["--autoConnect"]

    static let all: [MCPServerConfiguration] = [
        MCPServerConfiguration(
            name: "chrome-devtools",
            command: "npx",
            args: chromeArguments,
            enabled: false
        ),
        MCPServerConfiguration(
            name: "cua-driver",
            command: "cua-driver",
            args: ["mcp"],
            enabled: false
        )
    ]

    static func needsChromeAutoConnectMigration(_ server: MCPServerConfiguration) -> Bool {
        server.name == "chrome-devtools" && server.command == "npx"
            && server.args == legacyChromeArguments && server.env.isEmpty && server.transport == .stdio
    }
}

enum MCPEnvironmentParser {
    static func parse(_ text: String) -> [String: String] {
        var environment: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            environment[key] = value
        }
        return environment
    }
}

struct MCPToolDescriptor: Identifiable, Equatable {
    let serverID: UUID
    let serverName: String
    let name: String
    let title: String?
    let description: String?
    let risk: ActionToolRisk
    let inputSchemaJSON: String

    var id: String { "\(serverID.uuidString)/\(name)" }

    var displayName: String {
        title?.isEmpty == false ? (title ?? name) : name
    }
}

struct MCPServersDocument: Codable, Equatable {
    var mcpServers: [String: MCPServerEntry]

    struct MCPServerEntry: Codable, Equatable {
        var command: String
        var args: [String]?
        var env: [String: String]?
        var enabled: Bool?
        var transport: String?
    }

    static func document(from servers: [MCPServerConfiguration]) -> MCPServersDocument {
        var entries: [String: MCPServerEntry] = [:]
        for server in servers {
            entries[server.trimmedName] = MCPServerEntry(
                command: server.trimmedCommand,
                args: server.args.isEmpty ? nil : server.args,
                env: server.env.isEmpty ? nil : server.env,
                enabled: server.enabled,
                transport: server.transport.rawValue
            )
        }
        return MCPServersDocument(mcpServers: entries)
    }

    func configurations() -> [MCPServerConfiguration] {
        mcpServers
            .map { name, entry in
                MCPServerConfiguration(
                    name: name,
                    command: entry.command,
                    args: entry.args ?? [],
                    env: entry.env ?? [:],
                    enabled: entry.enabled ?? true,
                    transport: entry.transport.flatMap(MCPTransportKind.init(rawValue:)) ?? .stdio
                )
            }
            .sorted { $0.trimmedName.localizedCaseInsensitiveCompare($1.trimmedName) == .orderedAscending }
    }
}
