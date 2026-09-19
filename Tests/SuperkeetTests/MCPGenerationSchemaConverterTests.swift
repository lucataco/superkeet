import XCTest
import FoundationModels
@testable import Superkeet

@available(macOS 26.0, *)
final class MCPGenerationSchemaConverterTests: XCTestCase {
    func testConvertsTypedObjectSchema() {
        let json = """
        {"type":"object","properties":{"url":{"type":"string"},"count":{"type":"integer"},\
        "ratio":{"type":"number"},"flag":{"type":"boolean"}},"required":["url"]}
        """
        XCTAssertNotNil(MCPGenerationSchemaConverter.schema(fromJSON: json))
    }

    func testConvertsArraySchema() {
        let json = #"{"type":"array","items":{"type":"string"},"minItems":1}"#
        XCTAssertNotNil(MCPGenerationSchemaConverter.schema(fromJSON: json))
    }

    func testConvertsEnumSchema() {
        let json = #"{"type":"string","enum":["open","closed"]}"#
        XCTAssertNotNil(MCPGenerationSchemaConverter.schema(fromJSON: json))
    }

    func testConvertsParameterlessObjectSchema() {
        let json = #"{"type":"object","properties":{}}"#
        XCTAssertNotNil(MCPGenerationSchemaConverter.schema(fromJSON: json))
    }

    func testRejectsNonObjectJSON() {
        XCTAssertNil(MCPGenerationSchemaConverter.schema(fromJSON: "[]"))
        XCTAssertNil(MCPGenerationSchemaConverter.schema(fromJSON: ""))
    }

    func testToolBridgeDescriptionIsShortAndOmitsSchema() throws {
        let descriptor = MCPToolDescriptor(
            serverID: UUID(),
            serverName: "test",
            name: "click",
            title: nil,
            description: "Click an element by index or pixel coordinates from screenshot.",
            risk: .mutating,
            inputSchemaJSON: #"{"type":"object","properties":{"element_index":{"type":"string","description":"The uid of an element"}}}"#
        )
        let bridge = try XCTUnwrap(MCPToolBridge(spec: ActionToolSpec(descriptor: descriptor), execute: { _, _ in "" }))
        let described = String(describing: bridge)
        XCTAssertFalse(described.contains("inputSchemaJSON"))
        XCTAssertFalse(described.contains("properties"))
        XCTAssertLessThanOrEqual(described.count, 140)
    }

    @MainActor
    func testOpenInstructionsDependOnAvailableTools() {
        let native = FoundationModelActionPlanner.instructions(for: NativeOpenAction.tools)
        XCTAssertTrue(native.contains("use open_app"))
        XCTAssertTrue(native.contains("use open_url"))
        XCTAssertTrue(native.contains("use press_shortcut"))
        XCTAssertFalse(native.contains("open -a"))
        XCTAssertFalse(FoundationModelActionPlanner.instructions(for: Array(NativeOpenAction.tools.prefix(2))).contains("press_shortcut"))
        for name in ["run_process", "run_command"] {
            let shell = ActionToolSpec(descriptor: MCPToolDescriptor(serverID: UUID(), serverName: "commands", name: name,
                title: nil, description: nil, risk: .mutating, inputSchemaJSON: "{}"))
            XCTAssertTrue(FoundationModelActionPlanner.instructions(for: NativeOpenAction.tools + [shell]).contains("open -a"))
        }
        XCTAssertFalse(FoundationModelActionPlanner.instructions(for: []).contains("open -a"))
    }

    @MainActor
    func testStepContextIsAppendedToInstructionsOnlyWhenPresent() {
        var context = ActionPlanContext(command: "open the notes app and create a new note")
        let bare = FoundationModelActionPlanner.instructions(for: NativeOpenAction.tools, context: context, task: "create a new note")
        XCTAssertEqual(bare, FoundationModelActionPlanner.instructions(for: NativeOpenAction.tools), "An empty context adds nothing.")

        context.stepCount = 2
        context.stepNumber = 2
        context.completed.append(.init(clause: "open the notes app", summary: "Opened Notes (pid 4). Its window is on screen."))
        context.recordOpened(NativeLaunchedApp(name: "Notes", bundleIdentifier: nil, processIdentifier: 4, windowReady: true))
        let contextual = FoundationModelActionPlanner.instructions(for: NativeOpenAction.tools, context: context, task: "create a new note")
        XCTAssertTrue(contextual.hasPrefix(bare), "Context is appended after the standard instructions.")
        XCTAssertTrue(contextual.contains("step 2 only: \"create a new note\""))
        XCTAssertTrue(contextual.contains("Notes is already open (pid 4"))
    }

    private func encoded(_ schema: GenerationSchema) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try XCTUnwrap(String(data: encoder.encode(schema), encoding: .utf8))
    }

    func testPropertyDescriptionsSurviveConversionAndAreClipped() throws {
        let description = "Opaque target_id minted by get_browser_state. " + String(repeating: "extra ", count: 100)
        let json = #"{"type":"object","properties":{"target_id":{"type":"string","description":"\#(description)"}},"required":["target_id"]}"#
        let schema = try XCTUnwrap(MCPGenerationSchemaConverter.schema(fromJSON: json, toolName: "browser_navigate"))
        let rendered = try encoded(schema)
        XCTAssertTrue(rendered.contains(String(description.prefix(90))), rendered)
        XCTAssertFalse(rendered.contains(String(description.prefix(96))))
    }

    func testSchemaNamesAreDeterministicAndDistinctAcrossToolsAndPaths() throws {
        let json = #"{"type":"object","properties":{"a/b":{"type":"object","title":"Target","properties":{"id":{"type":"string"}}},"a_b":{"type":"object","title":"Target","properties":{"id":{"type":"integer"}}}}}"#
        let first = try XCTUnwrap(MCPGenerationSchemaConverter.schema(fromJSON: json, toolName: "click"))
        let repeated = try XCTUnwrap(MCPGenerationSchemaConverter.schema(fromJSON: json, toolName: "click"))
        let other = try XCTUnwrap(MCPGenerationSchemaConverter.schema(fromJSON: json, toolName: "type_text"))
        XCTAssertEqual(try encoded(first), try encoded(repeated))
        XCTAssertNotEqual(try encoded(first), try encoded(other))
        XCTAssertNotEqual(ActionToolSchema.name(toolName: "click", path: ["a/b"]), ActionToolSchema.name(toolName: "click", path: ["a", "b"]))
    }

    func testBridgeCachesStableParametersAcrossReadsAndServerIDs() throws {
        let first = try XCTUnwrap(MCPToolBridge(spec: NativeOpenAction.tools[1], execute: { _, _ in "" }))
        let spec = NativeOpenAction.tools[1]
        let equivalent = ActionToolSpec(descriptor: MCPToolDescriptor(serverID: UUID(), serverName: spec.serverName, name: spec.toolName,
            title: spec.displayName, description: spec.description, risk: spec.risk, inputSchemaJSON: spec.inputSchemaJSON))
        let other = try XCTUnwrap(MCPToolBridge(spec: equivalent, execute: { _, _ in "" }))
        XCTAssertEqual(try encoded(first.parameters), try encoded(first.parameters))
        XCTAssertEqual(try encoded(first.parameters), try encoded(other.parameters))
        XCTAssertEqual(first.estimatedTokenCost, ActionLimits.estimatedTokenCost(of: spec))
    }

    func testNullableScalarObjectAndArrayTypesKeepTheirNonNullShape() throws {
        for type in ["string", "integer", "number", "boolean", "object", "array"] {
            let json = #"{"type":"object","properties":{"value":{"type":["\#(type)","null"],"description":"Nullable argument"}},"required":["value"]}"#
            let schema = try XCTUnwrap(MCPGenerationSchemaConverter.schema(fromJSON: json, toolName: "nullable-\(type)"))
            let rendered = try encoded(schema)
            XCTAssertTrue(rendered.contains(type), rendered)
            XCTAssertTrue(rendered.contains("Nullable argument"))
            if #available(macOS 26.4, *) { XCTAssertTrue(rendered.contains("null"), rendered) }
        }
        let nested = #"{"type":"array","items":{"type":["string","null"]}}"#
        XCTAssertNotNil(MCPGenerationSchemaConverter.schema(fromJSON: nested))
    }

    func testUnsupportedRequiredSchemasDoNotTurnIntoEmptyObjects() {
        let json = #"{"type":"object","properties":{"id":{"type":["string","integer","null"]}},"required":["id"]}"#
        XCTAssertNil(MCPGenerationSchemaConverter.schema(fromJSON: json))
        let spec = ActionToolSpec(descriptor: MCPToolDescriptor(serverID: UUID(), serverName: "test", name: "broken",
            title: nil, description: nil, risk: .readOnly, inputSchemaJSON: json))
        XCTAssertNil(MCPToolBridge(spec: spec, execute: { _, _ in "" }))
    }

    func testNullableEnumsRetainChoicesAndDoNotInventNullPermission() throws {
        let nullable = #"{"type":"object","properties":{"mode":{"type":["string","null"],"enum":["background","foreground",null]}},"required":["mode"]}"#
        let schema = try XCTUnwrap(MCPGenerationSchemaConverter.schema(fromJSON: nullable))
        let rendered = try encoded(schema)
        XCTAssertTrue(rendered.contains("background"))
        XCTAssertTrue(rendered.contains("foreground"))
        let restricted = #"{"type":["string","null"],"enum":["background","foreground"]}"#
        let projected = try XCTUnwrap(ActionToolSchema.projected(restricted, toolName: "mode"))
        XCTAssertEqual(projected["type"] as? String, "string")
        XCTAssertEqual(projected["enum"] as? [String], ["background", "foreground"])
    }

    @MainActor
    func testPlannerRanksBeforeApplyingFortyToolCapAndKeepsNativeOpensFirst() throws {
        let fixture = try CuaToolRankingFixture.tools()
        let launch = try XCTUnwrap(fixture.first { $0.toolName == "launch_app" })
        let lateLaunch = fixture.filter { $0.toolName != "launch_app" } + [launch]
        let intent = HeuristicIntentExtractor.intent(for: "open discord")
        let bridges = FoundationModelActionPlanner.toolBridges(from: lateLaunch, intent: intent, execute: { _, _ in "" })
        XCTAssertEqual(bridges.count, 40)
        XCTAssertEqual(bridges.first?.name, "launch_app")
        let native = FoundationModelActionPlanner.toolBridges(from: lateLaunch + NativeOpenAction.tools, intent: intent, execute: { _, _ in "" })
        XCTAssertEqual(native.prefix(4).map(\.name), ["open_app", "open_url", "press_shortcut", "launch_app"])
    }

    @MainActor
    func testActiveTabPlannerUsesChromePagesWithoutNativeOpenTools() throws {
        let tools = NativeOpenAction.tools + ActiveTabToolFixture.chrome() + (try CuaToolRankingFixture.tools())
        let intent = HeuristicIntentExtractor.intent(for: "In the current tab, open Cloudflare DNS for catacolabs.com")
        let bridges = FoundationModelActionPlanner.toolBridges(from: tools, intent: intent, execute: { _, _ in "" })
        XCTAssertEqual(bridges.prefix(3).map(\.name), ["list_pages", "evaluate_script", "navigate_page"])
        XCTAssertTrue(bridges.allSatisfy { ActionToolFilter.isChromeAutomation($0.spec.serverName) })
        XCTAssertFalse(bridges.contains { $0.name == "new_page" || $0.name == "open_url" })
        let prompt = FoundationModelActionPlanner.instructions(for: bridges.map(\.spec), intent: intent)
        XCTAssertTrue(prompt.contains("Call list_pages first"))
        XCTAssertTrue(prompt.contains("not proof of the user's active tab"))
        XCTAssertTrue(prompt.contains("document.hasFocus()"))
        XCTAssertTrue(prompt.contains("bringToFront:false"))
        XCTAssertTrue(prompt.contains("Refresh page lists and snapshots"))
    }

    @MainActor
    func testCloudflareGuidanceSuppliesDashboardTemplateWithoutInventingZone() {
        let intent = HeuristicIntentExtractor.intent(for: "In the active tab, open Cloudflare DNS for catacolabs.com")
        let prompt = FoundationModelActionPlanner.instructions(for: ActiveTabToolFixture.chrome(), intent: intent)
        XCTAssertTrue(prompt.contains("https://dash.cloudflare.com/?to=/:account/<zone>/dns/records"))
        XCTAssertTrue(prompt.contains("exact domain supplied by the user"))
        XCTAssertTrue(prompt.contains("If the zone is unclear, ask"))
        XCTAssertTrue(prompt.contains("Navigation alone does not prove"))
        let ordinary = HeuristicIntentExtractor.intent(for: "Open youtube.com")
        XCTAssertFalse(FoundationModelActionPlanner.instructions(for: NativeOpenAction.tools, intent: ordinary).contains("dash.cloudflare.com"))
        XCTAssertFalse(FoundationModelActionPlanner.instructions(for: NativeOpenAction.tools, intent: ordinary).contains("document.hasFocus()"))
    }

    @MainActor
    func testActiveTabMissingChromeReportsSetupErrorBeforeModelOrExecution() async throws {
        let planner = FoundationModelActionPlanner()
        let tools = NativeOpenAction.tools + (try CuaToolRankingFixture.tools())
        do {
            _ = try await planner.run(task: "Find DNS in the active Chrome tab", tools: tools, maxSteps: 12,
                                      execute: { _, _ in XCTFail("No active-tab tool should run"); return "unexpected" }, onEvent: { _ in })
            XCTFail("Expected Chrome setup error")
        } catch {
            XCTAssertEqual(error as? ActionExecutionError, .activeChromeTabUnavailable)
        }
    }
}
