import XCTest
@testable import Superkeet

@MainActor
final class ActionToolDiscoveryTests: XCTestCase {
    final class Manager: ActionMCPManaging {
        var states: [UUID: MCPClientManager.ConnectionState] = [:]
        var inventory: [MCPToolDescriptor] = []
        var connected: [UUID] = []
        var onConnect: ((MCPServerConfiguration) -> Void)?
        func state(for id: UUID) -> MCPClientManager.ConnectionState { states[id] ?? .disconnected }
        func connect(_ server: MCPServerConfiguration) async {
            connected.append(server.id)
            states[server.id] = .connected
            onConnect?(server)
        }
        func allTools() -> [MCPToolDescriptor] { inventory.filter { states[$0.serverID] == .connected } }
        func callTool(serverID: UUID, toolName: String, argumentsJSON: String, structured: Bool) async throws -> String {
            XCTFail("Discovery must not execute tools")
            return "unused"
        }
    }

    @MainActor
    final class Fixture {
        let previousEnabled = AppSettings.shared.actionsEnabled
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manager = Manager()
        let store: MCPServerConfigStore
        let enabled = MCPServerConfiguration(name: "enabled", command: "fixture", enabled: true)
        let disabled = MCPServerConfiguration(name: "tested-only", command: "fixture", enabled: false)

        init() throws {
            store = MCPServerConfigStore(fileURL: directory.appendingPathComponent("servers.json"), secrets: InMemoryMCPSecretStore())
            try store.save([enabled, disabled])
            AppSettings.shared.actionsEnabled = true
            manager.inventory = [enabled, disabled].map { server in
                MCPToolDescriptor(serverID: server.id, serverName: server.name, name: "inspect", title: nil,
                                  description: nil, risk: .readOnly, inputSchemaJSON: "{}")
            }
        }

        var router: ActionToolRouter {
            ActionToolRouter(manager: manager, settings: .shared, configStore: store)
        }

        func cleanup() {
            AppSettings.shared.actionsEnabled = previousEnabled
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testTestConnectedDisabledServerNeverLeaksIntoPlan() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.manager.states[fixture.disabled.id] = .connected
        let tools = try await fixture.router.prepareTools()
        XCTAssertEqual(tools.map(\.serverID), [fixture.enabled.id])
        XCTAssertEqual(fixture.manager.connected, [fixture.enabled.id])
        XCTAssertEqual(fixture.manager.states[fixture.disabled.id], .connected)
    }

    func testLiveObservationsAreFlaggedForFreshExecution() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let server = fixture.enabled
        fixture.manager.inventory = [
            MCPToolDescriptor(serverID: server.id, serverName: server.name, name: "list_windows", title: nil,
                              description: nil, risk: .readOnly, inputSchemaJSON: "{}"),
            MCPToolDescriptor(serverID: server.id, serverName: server.name, name: "click", title: nil,
                              description: nil, risk: .mutating, inputSchemaJSON: "{}"),
            MCPToolDescriptor(serverID: server.id, serverName: server.name, name: "search_web", title: nil,
                              description: nil, risk: .readOnly, inputSchemaJSON: "{}")
        ]
        let tools = try await fixture.router.prepareTools()
        XCTAssertEqual(tools.map(\.toolName), ["list_windows", "click", "search_web"])
        XCTAssertEqual(tools.map(\.requiresFreshObservation), [true, false, false])
    }

    func testNoEnabledServersReportsHintEvenWhenTestLeftConnections() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.store.setEnabled(false, for: fixture.enabled.id)
        fixture.manager.states = [fixture.enabled.id: .connected, fixture.disabled.id: .connected]
        do {
            _ = try await fixture.router.prepareTools()
            XCTFail("Expected setup hint")
        } catch { XCTAssertEqual(error as? ActionExecutionError, .noMCPServersEnabled) }
        XCTAssertTrue(fixture.manager.connected.isEmpty)
    }

    func testActionsDisabledCannotUseConnectedInventory() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        AppSettings.shared.actionsEnabled = false
        fixture.manager.states[fixture.enabled.id] = .connected
        do {
            _ = try await fixture.router.prepareTools()
            XCTFail("Expected disabled action tools")
        } catch { XCTAssertEqual(error as? ActionExecutionError, .noMCPServersEnabled) }
        XCTAssertTrue(fixture.manager.connected.isEmpty)
    }

    func testEnabledIDsAreRecheckedAfterAwaitingConnections() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.manager.onConnect = { _ in fixture.store.setEnabled(false, for: fixture.enabled.id) }
        defer { fixture.manager.onConnect = nil }
        do {
            _ = try await fixture.router.prepareTools()
            XCTFail("Expected changed configuration to win")
        } catch { XCTAssertEqual(error as? ActionExecutionError, .noMCPServersEnabled) }
    }

    func testEnabledButUnavailableToolsReportConnectionProblemInstead() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.manager.inventory = []
        do {
            _ = try await fixture.router.prepareTools()
            XCTFail("Expected missing tool inventory")
        } catch { XCTAssertEqual(error as? ActionExecutionError, .noTools) }
    }

    func testCancelledDiscoveryDoesNotConnectServers() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let task = Task { try await fixture.router.prepareTools() }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(fixture.manager.connected.isEmpty)
    }
}
