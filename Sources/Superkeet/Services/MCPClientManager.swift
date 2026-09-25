import Foundation
import MCP
#if canImport(System)
import System
#else
import SystemPackage
#endif
import os.log

private let mcpLog = Logger(subsystem: "com.superkeet.app", category: "MCPClientManager")

enum MCPConnectionError: LocalizedError {
    case commandNotFound(String)
    case launchFailed(String)
    case timedOut
    case notConnected
    case toolReportedError(String)
    case toolFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandNotFound(let command):
            return "Could not find '\(command)'. Install it or use an absolute path so Superkeet can launch the MCP server."
        case .launchFailed(let detail):
            return "Could not launch the MCP server. \(detail)"
        case .timedOut:
            return "The MCP server did not finish its handshake in time."
        case .notConnected:
            return "The MCP server is not connected."
        case .toolReportedError(let detail):
            return detail.isEmpty ? "The tool reported an error." : detail
        case .toolFailed(let detail):
            return "The tool call failed. \(detail)"
        }
    }
}

@MainActor
final class MCPClientManager: ObservableObject, ActionMCPManaging {
    static let shared = MCPClientManager()

    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)

        var label: String {
            switch self {
            case .disconnected: return "Not connected"
            case .connecting: return "Connecting…"
            case .connected: return "Connected"
            case .failed(let message): return message
            }
        }

        var isConnected: Bool { self == .connected }
    }

    @Published private(set) var states: [UUID: ConnectionState] = [:]
    @Published private(set) var toolsByServer: [UUID: [MCPToolDescriptor]] = [:]

    private let injectedConfigStore: MCPServerConfigStore?
    private var configStore: MCPServerConfigStore { injectedConfigStore ?? .shared }
    private var connections: [UUID: Connection] = [:]
    private var connectionGenerations: [UUID: UUID] = [:]
    private let connector: (@MainActor (MCPServerConfiguration, UUID) async throws -> Connection)?
    private let toolLoader: (@MainActor (MCPServerConfiguration, Connection, UUID) async throws -> [MCPToolDescriptor])?
    private let connectTimeoutSeconds: Double = 60

    init(
        configStore: MCPServerConfigStore? = nil,
        connector: (@MainActor (MCPServerConfiguration, UUID) async throws -> Connection)? = nil,
        toolLoader: (@MainActor (MCPServerConfiguration, Connection, UUID) async throws -> [MCPToolDescriptor])? = nil
    ) {
        self.injectedConfigStore = configStore
        self.connector = connector
        self.toolLoader = toolLoader
    }

    func state(for id: UUID) -> ConnectionState {
        states[id] ?? .disconnected
    }

    func tools(for id: UUID) -> [MCPToolDescriptor] {
        toolsByServer[id] ?? []
    }

    func allTools() -> [MCPToolDescriptor] {
        toolsByServer
            .filter { states[$0.key]?.isConnected == true }
            .values
            .flatMap { $0 }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func connectAllEnabled() async {
        for server in configStore.enabledServers {
            await connect(server)
        }
    }

    /// Warm-up for app launch and for the moment Actions Mode or a server is switched on: connect
    /// enabled servers that are not connected yet, and leave healthy connections alone.
    func connectEnabledServersIfNeeded(settings: AppSettings = .shared) async {
        guard settings.actionsEnabled else { return }
        for server in configStore.enabledServers {
            guard case .disconnected = state(for: server.id) else { continue }
            await connect(server)
        }
    }

    func disconnectAll() async {
        for id in Set(connections.keys).union(connectionGenerations.keys) {
            await disconnect(id)
        }
    }

    func connect(_ server: MCPServerConfiguration) async {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !Task.isCancelled else { return }
        let generation = UUID()
        connectionGenerations[server.id] = generation
        await withTaskCancellationHandler {
            await connect(server, generation: generation)
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.connectionGenerations[server.id] == generation else { return }
                await self.disconnect(server.id)
            }
        }
    }

    private func connect(_ server: MCPServerConfiguration, generation: UUID) async {
        dispatchPrecondition(condition: .onQueue(.main))
        guard connectionGenerations[server.id] == generation, !Task.isCancelled else { return }
        await disconnectConnection(server.id)
        guard connectionGenerations[server.id] == generation, !Task.isCancelled else { return }
        states[server.id] = .connecting
        do {
            let connection: Connection
            if let connector {
                connection = try await connector(server, generation)
            } else {
                connection = try await performConnect(server, generation: generation)
            }
            guard connectionGenerations[server.id] == generation, !Task.isCancelled else {
                connection.cleanup()
                await connection.client.disconnect()
                return
            }
            connections[server.id] = connection
            let tools: [MCPToolDescriptor]
            if let toolLoader {
                tools = try await toolLoader(server, connection, generation)
            } else {
                tools = try await loadTools(server, client: connection.client)
            }
            guard connectionGenerations[server.id] == generation, connections[server.id] === connection,
                  !Task.isCancelled else { return }
            toolsByServer[server.id] = tools
            states[server.id] = .connected
            mcpLog.info("Connected MCP server \(server.trimmedName, privacy: .public) with \(tools.count) tools")
        } catch {
            guard connectionGenerations[server.id] == generation else { return }
            let message = error.localizedDescription
            let excerpt = connections[server.id]?.stderrExcerpt
            let combined = [message, excerpt].compactMap { $0 }.joined(separator: "\n")
            await disconnectConnection(server.id)
            guard connectionGenerations[server.id] == generation else { return }
            connectionGenerations[server.id] = nil
            if Task.isCancelled || ActionErrorHandling.isCancellation(error) { return }
            toolsByServer[server.id] = nil
            states[server.id] = .failed(combined)
            mcpLog.error("MCP connect failed for \(server.trimmedName, privacy: .public): \(message, privacy: .public)")
        }
    }

    func disconnect(_ id: UUID) async {
        dispatchPrecondition(condition: .onQueue(.main))
        connectionGenerations[id] = nil
        await disconnectConnection(id)
    }

    private func disconnectConnection(_ id: UUID) async {
        dispatchPrecondition(condition: .onQueue(.main))
        states[id] = .disconnected
        toolsByServer[id] = nil
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.cleanup()
        await connection.client.disconnect()
    }

    func callTool(serverID: UUID, toolName: String, argumentsJSON: String, structured: Bool = false) async throws -> String {
        try Task.checkCancellation()
        guard let connection = connections[serverID], states[serverID]?.isConnected == true else {
            throw MCPConnectionError.notConnected
        }
        let arguments = Self.decodeArguments(argumentsJSON)
        do {
            let context = try await connection.client.send(CallTool.request(.init(name: toolName, arguments: arguments)))
            let result = try await context.value
            try Task.checkCancellation()
            let text = Self.summarize(result.content)
            if result.isError == true {
                throw MCPConnectionError.toolReportedError(text)
            }
            if structured {
                guard let content = result.structuredContent else { return text }
                let data = try JSONEncoder().encode(content)
                guard data.count <= ActionJSON.maximumStructuredResultBytes else {
                    throw MCPConnectionError.toolFailed("The structured result exceeds 1 MB; narrow the observation.")
                }
                guard let json = String(data: data, encoding: .utf8) else {
                    throw MCPConnectionError.toolFailed("The structured result is not valid UTF-8.")
                }
                return json
            }
            return text
        } catch let error as MCPConnectionError {
            throw error
        } catch {
            if ActionErrorHandling.isCancellation(error) { throw CancellationError() }
            throw MCPConnectionError.toolFailed(error.localizedDescription)
        }
    }

    static func decodeArguments(_ json: String) -> [String: Value]? {
        guard !json.isEmpty, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String: Value].self, from: data)
    }

    static func encodeSchema(_ schema: Value) -> String {
        guard let data = try? JSONEncoder().encode(schema),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    static func summarize(_ content: [MCP.Tool.Content]) -> String {
        content.map { item in
            switch item {
            case .text(let text, _, _):
                return text
            case .image:
                return "[image]"
            case .audio:
                return "[audio]"
            case .resource(let resource, _, _):
                return resource.text ?? "[resource: \(resource.uri)]"
            case .resourceLink(let uri, let name, _, _, _, _):
                return "[\(name)](\(uri))"
            }
        }
        .joined(separator: "\n")
    }

    private func performConnect(_ server: MCPServerConfiguration, generation: UUID) async throws -> Connection {
        dispatchPrecondition(condition: .onQueue(.main))
        let searchPath = await LoginShellPath.current()
        try Task.checkCancellation()
        guard connectionGenerations[server.id] == generation else { throw CancellationError() }
        guard let executable = MCPExecutableResolver.resolve(command: server.command, searchPath: searchPath) else {
            throw MCPConnectionError.commandNotFound(server.trimmedCommand)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = server.args
        var environment: [String: String] = [
            "PATH": searchPath,
            "HOME": NSHomeDirectory(),
            "LANG": ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8",
            "TERM": "dumb"
        ]
        for (key, value) in server.env { environment[key] = value }
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let client = MCP.Client(name: "Superkeet", version: AppVersion.current.shortVersion)
        let connection = Connection(
            server: server,
            client: client,
            process: process,
            stdinPipe: stdinPipe,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe
        )

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            connection.appendStderr(text)
        }

        process.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                self?.handleTermination(serverID: server.id, generation: generation, status: proc.terminationStatus)
            }
        }

        connections[server.id] = connection

        do {
            try process.run()
        } catch {
            connection.cleanup()
            throw MCPConnectionError.launchFailed(error.localizedDescription)
        }

        let transport = StdioTransport(
            input: FileDescriptor(rawValue: stdoutPipe.fileHandleForReading.fileDescriptor),
            output: FileDescriptor(rawValue: stdinPipe.fileHandleForWriting.fileDescriptor)
        )

        do {
            _ = try await AsyncTimeout.run(
                seconds: connectTimeoutSeconds,
                timeoutError: MCPConnectionError.timedOut
            ) {
                try await client.connect(transport: transport)
            }
        } catch {
            connection.cleanup()
            throw error
        }

        return connection
    }

    private func loadTools(_ server: MCPServerConfiguration, client: MCP.Client) async throws -> [MCPToolDescriptor] {
        var descriptors: [MCPToolDescriptor] = []
        var cursor: String?
        while true {
            try Task.checkCancellation()
            let (page, nextCursor) = try await client.listTools(cursor: cursor)
            try Task.checkCancellation()
            for tool in page {
                let annotations = MCPToolAnnotations(
                    readOnlyHint: tool.annotations.readOnlyHint,
                    destructiveHint: tool.annotations.destructiveHint,
                    idempotentHint: tool.annotations.idempotentHint,
                    openWorldHint: tool.annotations.openWorldHint
                )
                descriptors.append(
                    MCPToolDescriptor(
                        serverID: server.id,
                        serverName: server.trimmedName,
                        name: tool.name,
                        title: tool.title,
                        description: tool.description,
                        risk: MCPToolRiskClassifier.risk(for: annotations, name: tool.name),
                        inputSchemaJSON: Self.encodeSchema(tool.inputSchema)
                    )
                )
            }
            guard let next = nextCursor, !next.isEmpty else { break }
            cursor = next
        }
        return descriptors
    }

    func handleTermination(serverID: UUID, generation: UUID, status: Int32) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard connectionGenerations[serverID] == generation, let connection = connections.removeValue(forKey: serverID) else { return }
        connectionGenerations[serverID] = nil
        states[serverID] = .failed("The MCP server exited (code \(status)).")
        toolsByServer[serverID] = nil
        connection.cleanup()
        Task { await connection.client.disconnect() }
    }

    final class Connection: @unchecked Sendable {
        let server: MCPServerConfiguration
        let client: MCP.Client
        let process: Process
        let stdinPipe: Pipe
        let stdoutPipe: Pipe
        let stderrPipe: Pipe

        private let lock = NSLock()
        private var stderrLines: [String] = []

        init(
            server: MCPServerConfiguration,
            client: MCP.Client,
            process: Process,
            stdinPipe: Pipe,
            stdoutPipe: Pipe,
            stderrPipe: Pipe
        ) {
            self.server = server
            self.client = client
            self.process = process
            self.stdinPipe = stdinPipe
            self.stdoutPipe = stdoutPipe
            self.stderrPipe = stderrPipe
        }

        func appendStderr(_ text: String) {
            lock.lock()
            defer { lock.unlock() }
            stderrLines.append(contentsOf: text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
            if stderrLines.count > 30 {
                stderrLines.removeFirst(stderrLines.count - 30)
            }
        }

        var stderrExcerpt: String? {
            lock.lock()
            defer { lock.unlock() }
            let joined = stderrLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        }

        func cleanup() {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            guard process.isRunning else { return }
            process.terminate()
            // Escalate if the server ignores SIGTERM so it can't outlive Superkeet.
            let process = process
            let pid = process.processIdentifier
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0) {
                guard process.isRunning, process.processIdentifier == pid else { return }
                kill(pid, SIGKILL)
            }
        }
    }
}
