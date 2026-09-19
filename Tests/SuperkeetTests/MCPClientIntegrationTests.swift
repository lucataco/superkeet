import XCTest
@testable import Superkeet

final class MCPClientIntegrationTests: XCTestCase {

    @MainActor
    func testPreservesStructuredContentSeparatelyFromTextSummary() async throws {
        let script = #"""
        import json, sys
        for line in sys.stdin:
            request = json.loads(line)
            if "id" not in request:
                continue
            method = request["method"]
            if method == "initialize":
                result = {"protocolVersion":request["params"]["protocolVersion"], "capabilities":{"tools":{}},
                          "serverInfo":{"name":"fixture","version":"1"}}
            elif method == "tools/list":
                result = {"tools":[{"name":"observe","inputSchema":{"type":"object"}}]}
            elif method == "tools/call":
                result = {"content":[{"type":"text","text":"short summary"}],
                          "structuredContent":{"snapshot_id":"s00000001","value":"x" * 2000}}
            else:
                result = {}
            print(json.dumps({"jsonrpc":"2.0","id":request["id"],"result":result}), flush=True)
        """#
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".py")
        try script.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let server = MCPServerConfiguration(name: "structured-fixture", command: "/usr/bin/python3", args: ["-u", file.path])
        let manager = MCPClientManager()
        await manager.connect(server)
        do {
            XCTAssertTrue(manager.state(for: server.id).isConnected)
            let plain = try await manager.callTool(serverID: server.id, toolName: "observe", argumentsJSON: "{}")
            XCTAssertEqual(plain, "short summary")
            let structured = try await manager.callTool(serverID: server.id, toolName: "observe", argumentsJSON: "{}", structured: true)
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(structured.utf8)) as? [String: Any])
            XCTAssertEqual(root["snapshot_id"] as? String, "s00000001")
            XCTAssertEqual((root["value"] as? String)?.count, 2000)
        } catch {
            await manager.disconnect(server.id)
            throw error
        }
        await manager.disconnect(server.id)
    }

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
