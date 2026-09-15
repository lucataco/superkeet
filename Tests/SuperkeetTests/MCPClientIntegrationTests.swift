import XCTest
@testable import Superkeet

final class MCPClientIntegrationTests: XCTestCase {

    @MainActor
    func testConnectsToListedServer() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let command = environment["SUPERKEET_MCP_TEST_COMMAND"], !command.isEmpty else {
            throw XCTSkip("Set SUPERKEET_MCP_TEST_COMMAND (and optional SUPERKEET_MCP_TEST_ARGS) to run.")
        }
        let args = (environment["SUPERKEET_MCP_TEST_ARGS"] ?? "")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)

        let server = MCPServerConfiguration(name: "integration", command: command, args: args)
        let manager = MCPClientManager()
        await manager.connect(server)
        defer { Task { await manager.disconnect(server.id) } }

        let state = manager.state(for: server.id)
        XCTAssertTrue(state.isConnected, "Expected a connection but got: \(state.label)")
        XCTAssertFalse(manager.tools(for: server.id).isEmpty, "Expected the server to expose at least one tool.")
    }

    @MainActor
    func testCallsEchoToolWhenAvailable() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let command = environment["SUPERKEET_MCP_TEST_COMMAND"], !command.isEmpty else {
            throw XCTSkip("Set SUPERKEET_MCP_TEST_COMMAND (and optional SUPERKEET_MCP_TEST_ARGS) to run.")
        }
        let args = (environment["SUPERKEET_MCP_TEST_ARGS"] ?? "")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)

        let server = MCPServerConfiguration(name: "integration", command: command, args: args)
        let manager = MCPClientManager()
        await manager.connect(server)
        defer { Task { await manager.disconnect(server.id) } }

        guard let echo = manager.tools(for: server.id).first(where: { $0.name == "echo" }) else {
            throw XCTSkip("The configured server does not expose an 'echo' tool.")
        }
        let output = try await manager.callTool(
            serverID: server.id,
            toolName: echo.name,
            argumentsJSON: #"{"message":"ping"}"#
        )
        XCTAssertTrue(output.lowercased().contains("ping"), "Unexpected echo output: \(output)")
    }
}
