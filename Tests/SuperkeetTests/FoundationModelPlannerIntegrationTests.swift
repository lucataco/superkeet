import XCTest
@testable import Superkeet

@available(macOS 26.0, *)
final class FoundationModelPlannerIntegrationTests: XCTestCase {

    @MainActor
    func testModelCallsRealMCPEchoTool() async throws {
        guard AppleIntelligenceAvailability.current.isAvailable else {
            throw XCTSkip("Apple Intelligence is not available on this machine.")
        }
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
        guard manager.state(for: server.id).isConnected else {
            throw XCTSkip("The configured MCP server did not connect.")
        }

        let specs = manager.tools(for: server.id).map(ActionToolSpec.init)
        let planner = FoundationModelActionPlanner()
        let output = try await planner.run(
            task: "Use the echo tool to echo the words 'pineapple pizza', then tell me the exact text it returned.",
            tools: specs,
            maxSteps: 4,
            execute: { spec, arguments in
                try await manager.callTool(serverID: spec.serverID, toolName: spec.toolName, argumentsJSON: arguments)
            },
            onEvent: { _ in }
        )
        XCTAssertTrue(
            output.lowercased().contains("pineapple"),
            "Model did not surface the echoed text. Output: \(output)"
        )
    }

    final class ToolCallRecorder: @unchecked Sendable {
        var toolName: String?
        var arguments: String?
        var calls: [(String, String)] = []
    }

    @MainActor
    func testModelUsesStepContextAndShortcutToolForSecondStep() async throws {
        guard ProcessInfo.processInfo.environment["SUPERKEET_FM_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set SUPERKEET_FM_LIVE_TESTS=1 to exercise the on-device model.")
        }
        guard AppleIntelligenceAvailability.current.isAvailable else {
            throw XCTSkip("Apple Intelligence is not available on this machine.")
        }
        var context = ActionPlanContext(command: "open the notes app and create a new note")
        context.stepCount = 2
        context.stepNumber = 2
        context.completed.append(.init(clause: "open the notes app", summary: "Opened Notes (pid 4242, com.apple.Notes). Its window is on screen."))
        context.recordOpened(NativeLaunchedApp(name: "Notes", bundleIdentifier: "com.apple.Notes", processIdentifier: 4242, windowReady: true))

        let recorder = ToolCallRecorder()
        let planner = FoundationModelActionPlanner()
        let output = try await planner.run(
            step: ActionPlanStep(task: "create a new note", context: context),
            tools: NativeOpenAction.tools,
            maxSteps: 4,
            execute: { spec, arguments in
                recorder.calls.append((spec.toolName, arguments))
                return spec.toolName == "press_shortcut" ? "Pressed ⌘N in Notes (pid 4242)." : "Opened Notes (pid 4242, com.apple.Notes). Its window is on screen."
            },
            onEvent: { _ in }
        )
        print("FM_LIVE calls:", recorder.calls, "output:", output)
        XCTAssertFalse(recorder.calls.contains { $0.0 == "open_app" }, "Notes was already open; the model must not reopen it.")
        let shortcut = recorder.calls.first { $0.0 == "press_shortcut" }
        XCTAssertNotNil(shortcut, "Expected one press_shortcut call. Calls: \(recorder.calls)")
        if let shortcut {
            XCTAssertEqual(try NativeOpenAction.decode(toolName: "press_shortcut", argumentsJSON: shortcut.1),
                           .pressShortcut(app: "Notes", shortcut: try XCTUnwrap(KeyboardShortcut(keys: ["cmd", "n"]))))
        }
    }

    @MainActor
    func testModelChoosesRunProcessToOpenAnApp() async throws {
        guard AppleIntelligenceAvailability.current.isAvailable else {
            throw XCTSkip("Apple Intelligence is not available on this machine.")
        }
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
        guard manager.state(for: server.id).isConnected else {
            throw XCTSkip("The configured MCP server did not connect.")
        }
        let specs = manager.tools(for: server.id).map(ActionToolSpec.init)
        guard specs.contains(where: { $0.toolName == "run_process" }) else {
            throw XCTSkip("This test requires the mcp-server-commands 'run_process' tool.")
        }

        let recorder = ToolCallRecorder()
        let planner = FoundationModelActionPlanner()
        _ = try await planner.run(
            task: "Open the Helium browser for me.",
            tools: specs,
            maxSteps: 3,
            execute: { spec, arguments in
                recorder.toolName = spec.toolName
                recorder.arguments = arguments
                return "Command started."
            },
            onEvent: { _ in }
        )

        XCTAssertEqual(recorder.toolName, "run_process", "The model should use the command tool to open an app.")
        XCTAssertTrue(
            recorder.arguments?.lowercased().contains("helium") == true,
            "The command arguments should target Helium. Got: \(recorder.arguments ?? "nil")"
        )
    }
}
