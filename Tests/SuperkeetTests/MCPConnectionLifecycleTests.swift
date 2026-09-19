import XCTest
import MCP
@testable import Superkeet

@MainActor
final class MCPConnectionLifecycleTests: XCTestCase {
    private func connection(_ server: MCPServerConfiguration) -> MCPClientManager.Connection {
        MCPClientManager.Connection(server: server, client: MCP.Client(name: "fixture", version: "1"), process: Process(),
                                    stdinPipe: Pipe(), stdoutPipe: Pipe(), stderrPipe: Pipe())
    }

    private func tool(_ name: String, server: MCPServerConfiguration) -> MCPToolDescriptor {
        MCPToolDescriptor(serverID: server.id, serverName: server.name, name: name, title: nil,
                          description: nil, risk: .readOnly, inputSchemaJSON: "{}")
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for connection fixture")
        throw ActionExecutionError.timedOut
    }

    func testLateInventoryAndTerminationCannotOverwriteReplacement() async throws {
        for failOldLoad in [false, true] {
            let server = MCPServerConfiguration(name: "fixture", command: "unused")
            let gate = ActionTestGate<[MCPToolDescriptor]>()
            var generations: [UUID] = []
            let manager = MCPClientManager(connector: { server, generation in
                generations.append(generation)
                return self.connection(server)
            }, toolLoader: { server, _, generation in
                if generation == generations.first { return try await gate.wait() }
                return [self.tool("current", server: server)]
            })
            let old = Task { await manager.connect(server) }
            try await waitFor { gate.entered }
            await manager.connect(server)
            XCTAssertEqual(manager.state(for: server.id), .connected)
            gate.resolve(failOldLoad ? .failure(MCPConnectionError.timedOut) : .success([tool("stale", server: server)]))
            await old.value
            XCTAssertEqual(manager.tools(for: server.id).map(\.name), ["current"])
            XCTAssertEqual(manager.state(for: server.id), .connected)
            manager.handleTermination(serverID: server.id, generation: try XCTUnwrap(generations.first), status: 1)
            XCTAssertEqual(manager.state(for: server.id), .connected)
            XCTAssertEqual(manager.tools(for: server.id).map(\.name), ["current"])
            manager.handleTermination(serverID: server.id, generation: try XCTUnwrap(generations.last), status: 7)
            XCTAssertEqual(manager.state(for: server.id), .failed("The MCP server exited (code 7)."))
            XCTAssertTrue(manager.tools(for: server.id).isEmpty)
            await manager.disconnectAll()
        }
    }

    func testLateHandshakeAndCancelledOldAttemptCannotDisconnectNewConnection() async throws {
        let server = MCPServerConfiguration(name: "fixture", command: "unused")
        let gate = ActionTestGate<MCPClientManager.Connection>()
        var attempts = 0
        let manager = MCPClientManager(connector: { server, _ in
            attempts += 1
            if attempts == 1 { return try await gate.wait() }
            return self.connection(server)
        }, toolLoader: { server, _, _ in [self.tool("current", server: server)] })
        let old = Task { await manager.connect(server) }
        try await waitFor { gate.entered }
        await manager.connect(server)
        old.cancel()
        gate.resolve(.success(connection(server)))
        await old.value
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(manager.state(for: server.id), .connected)
        XCTAssertEqual(manager.tools(for: server.id).map(\.name), ["current"])
        await manager.disconnectAll()
    }

    func testDisconnectAllInvalidatesPendingHandshake() async throws {
        let server = MCPServerConfiguration(name: "fixture", command: "unused")
        let gate = ActionTestGate<MCPClientManager.Connection>()
        let manager = MCPClientManager(connector: { _, _ in try await gate.wait() }, toolLoader: { server, _, _ in
            XCTFail("Disconnected handshake must not load tools")
            return [self.tool("stale", server: server)]
        })
        let pending = Task { await manager.connect(server) }
        try await waitFor { gate.entered }
        await manager.disconnectAll()
        gate.resolve(.success(connection(server)))
        await pending.value
        XCTAssertEqual(manager.state(for: server.id), .disconnected)
        XCTAssertTrue(manager.allTools().isEmpty)
    }

    func testCancellationInterruptsRegisteredConnectionWhileToolListIsPending() async throws {
        let server = MCPServerConfiguration(name: "fixture", command: "unused")
        let gate = ActionTestGate<[MCPToolDescriptor]>()
        let manager = MCPClientManager(connector: { server, _ in self.connection(server) }, toolLoader: { _, _, _ in try await gate.wait() })
        let pending = Task { await manager.connect(server) }
        try await waitFor { gate.entered }
        pending.cancel()
        try await waitFor { manager.state(for: server.id) == .disconnected }
        gate.resolve(.success([tool("stale", server: server)]))
        await pending.value
        XCTAssertTrue(manager.allTools().isEmpty)
        XCTAssertEqual(manager.state(for: server.id), .disconnected)
    }

    func testWrappedConnectionCancellationDoesNotPublishFailure() async {
        let server = MCPServerConfiguration(name: "fixture", command: "unused")
        let manager = MCPClientManager(connector: { _, _ in
            throw NSError(domain: "fixture", code: 1, userInfo: [NSUnderlyingErrorKey: CancellationError()])
        })
        await manager.connect(server)
        XCTAssertEqual(manager.state(for: server.id), .disconnected)
        XCTAssertTrue(manager.allTools().isEmpty)
    }
}
