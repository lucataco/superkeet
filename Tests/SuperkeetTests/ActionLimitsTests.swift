import XCTest
@testable import Superkeet

final class ActionLimitsTests: XCTestCase {
    private func makeTool(_ index: Int) -> ActionToolSpec {
        ActionToolSpec(descriptor: MCPToolDescriptor(
            serverID: UUID(),
            serverName: "test",
            name: "tool\(index)",
            title: nil,
            description: nil,
            risk: .readOnly,
            inputSchemaJSON: "{}"
        ))
    }

    func testLimitedToolsKeepsSmallListUnchanged() {
        let tools = (0..<10).map(makeTool)
        XCTAssertEqual(ActionLimits.limitedTools(tools).count, 10)
    }

    func testLimitedToolsCapsLargeList() {
        let tools = (0..<100).map(makeTool)
        let limited = ActionLimits.limitedTools(tools)
        XCTAssertEqual(limited.count, ActionLimits.maximumToolsPerAction)
        XCTAssertEqual(limited.first?.toolName, "tool0")
    }

    func testValidateArgumentsAcceptsSmallPayload() throws {
        XCTAssertNoThrow(try ActionLimits.validateArguments(#"{"q":"hello"}"#))
    }

    func testValidateArgumentsRejectsOversizedPayload() {
        let payload = String(repeating: "a", count: ActionLimits.maximumArgumentsBytes + 1)
        XCTAssertThrowsError(try ActionLimits.validateArguments(payload)) { error in
            XCTAssertEqual(error as? ActionExecutionError, .argumentsTooLarge)
        }
    }

    private func makeSpec(
        server: UUID,
        name: String,
        description: String = "",
        schema: String = "{}"
    ) -> ActionToolSpec {
        ActionToolSpec(descriptor: MCPToolDescriptor(
            serverID: server,
            serverName: "server-\(server.uuidString.prefix(4))",
            name: name,
            title: nil,
            description: description,
            risk: .readOnly,
            inputSchemaJSON: schema
        ))
    }

    func testPrioritizedToolsKeepsEveryToolExactlyOnce() {
        let serverA = UUID()
        let serverB = UUID()
        let specs = [
            makeSpec(server: serverA, name: "a0"),
            makeSpec(server: serverA, name: "a1"),
            makeSpec(server: serverB, name: "b0")
        ]
        let ordered = ActionLimits.prioritizedTools(specs, task: "do something")
        XCTAssertEqual(ordered.count, specs.count)
        XCTAssertEqual(Set(ordered.map(\.id)), Set(specs.map(\.id)))
    }

    func testPrioritizedToolsRoundRobinsAcrossServers() {
        let serverA = UUID()
        let serverB = UUID()
        let a0 = makeSpec(server: serverA, name: "a0")
        let a1 = makeSpec(server: serverA, name: "a1")
        let b0 = makeSpec(server: serverB, name: "b0")
        let ordered = ActionLimits.prioritizedTools([a0, a1, b0], task: "do something")
        let firstA1 = ordered.firstIndex(of: a1)
        let firstB0 = ordered.firstIndex(of: b0)
        XCTAssertNotNil(firstA1)
        XCTAssertNotNil(firstB0)
        if let firstA1, let firstB0 {
            XCTAssertLessThan(firstB0, firstA1, "Tools should alternate between servers so each is represented.")
        }
    }

    func testPrioritizedToolsSurfacesTaskRelevantToolFirst() {
        let serverA = UUID()
        let serverB = UUID()
        let screenshot = makeSpec(server: serverA, name: "take_screenshot", description: "Capture the screen")
        let click = makeSpec(server: serverA, name: "click", description: "Click a button")
        let unrelated = makeSpec(server: serverB, name: "run_process", description: "Run a command")
        let ordered = ActionLimits.prioritizedTools(
            [click, unrelated, screenshot],
            task: "take a screenshot please"
        )
        XCTAssertEqual(ordered.first?.id, screenshot.id)
    }

    func testEstimatedTokenCostGrowsWithDefinitionSize() {
        let server = UUID()
        let small = makeSpec(server: server, name: "small", schema: "{\"type\":\"object\"}")
        let large = makeSpec(
            server: server,
            name: "large_tool_with_a_long_name",
            description: String(repeating: "describe ", count: 20),
            schema: "{\"type\":\"object\",\"properties\":{\"one\":{\"type\":\"string\"},\"two\":{\"type\":\"integer\"}}}"
        )
        XCTAssertGreaterThan(
            ActionLimits.estimatedTokenCost(of: large),
            ActionLimits.estimatedTokenCost(of: small)
        )
    }

    func testRelevanceScoreMatchesTaskTerms() {
        let server = UUID()
        let matching = makeSpec(server: server, name: "navigate_page", description: "Open a URL")
        let other = makeSpec(server: server, name: "click", description: "Click a button")
        XCTAssertGreaterThan(
            ActionLimits.relevanceScore(of: matching, task: "navigate to a page"),
            ActionLimits.relevanceScore(of: other, task: "navigate to a page")
        )
    }

    func testLaunchAppRanksFirstAgainstReal56ToolCuaInventory() throws {
        let tools = try CuaToolRankingFixture.tools()
        XCTAssertEqual(tools.count, 56)
        XCTAssertEqual(tools.reduce(0) { $0 + $1.description.unicodeScalars.count }, 37_159)
        let ordered = ActionLimits.prioritizedTools(tools, task: "open discord")
        XCTAssertEqual(ordered.first?.toolName, "launch_app")
        XCTAssertEqual(Array(ordered.prefix(3).map(\.toolName)), ["launch_app", "bring_to_front", "list_apps"])
        XCTAssertEqual(ActionLimits.prioritizedTools(Array(tools.reversed()), task: "open discord"), ordered)
    }

    func testIntentPreferencesBeatGenericDescriptionNoise() {
        let server = UUID()
        for (action, preferred) in [(ActionIntent.Action.openApp, "launch_app"), (.openURL, "new_page"),
                                    (.click, "get_window_state"), (.readScreen, "get_window_state")] {
            let intent = ActionIntent(goal: "the and com open", action: action)
            let noise = makeSpec(server: server, name: "aaa_noise", description: "open and the com " + String(repeating: "open ", count: 200))
            let match = makeSpec(server: server, name: preferred)
            XCTAssertEqual(ActionLimits.relevanceScore(of: noise, intent: intent), 0)
            XCTAssertEqual(ActionLimits.prioritizedTools([noise, match], intent: intent).first, match)
        }
    }

    func testEqualScoresRemainStableAcrossInventoryOrderAndRoundRobin() {
        let serverA = UUID()
        let serverB = UUID()
        let tools = [makeSpec(server: serverA, name: "same"), makeSpec(server: serverA, name: "second"),
                     makeSpec(server: serverB, name: "same"), makeSpec(server: serverB, name: "second")]
        let ordered = ActionLimits.prioritizedTools(tools, task: "unrelated")
        XCTAssertEqual(ActionLimits.prioritizedTools(Array(tools.reversed()), task: "unrelated"), ordered)
        XCTAssertEqual(Set(ordered.prefix(2).map(\.serverID)).count, 2)
    }

    func testGrounderPreferenceAppliesOnlyToGroundableIntents() {
        let helper = makeSpec(server: UUID(), name: "superkeet_native_click")
        XCTAssertEqual(ActionLimits.relevanceScore(of: helper, intent: .init(goal: "unrelated", action: .openApp)), 0)
        XCTAssertGreaterThan(ActionLimits.relevanceScore(of: helper, intent: .init(goal: "unrelated", action: .click)), 0)
    }

    func testTokenEstimateClipsToolAndPropertyDescriptionsLikeBridge() {
        let server = UUID()
        let base = String(repeating: "x", count: ActionToolSchema.toolDescriptionLimit)
        let short = makeSpec(server: server, name: "inspect", description: base)
        let long = makeSpec(server: server, name: "inspect", description: base + String(repeating: "ignored", count: 1_000))
        XCTAssertEqual(ActionLimits.estimatedTokenCost(of: short), ActionLimits.estimatedTokenCost(of: long))
        let propertyBase = String(repeating: "x", count: ActionToolSchema.propertyDescriptionLimit)
        func described(_ text: String) -> ActionToolSpec {
            makeSpec(server: server, name: "inspect", schema: #"{"type":"object","properties":{"id":{"type":"string","description":"\#(text)"}}}"#)
        }
        XCTAssertGreaterThan(ActionLimits.estimatedTokenCost(of: described(propertyBase)), ActionLimits.estimatedTokenCost(of: described("")))
        XCTAssertEqual(ActionLimits.estimatedTokenCost(of: described(propertyBase)),
                       ActionLimits.estimatedTokenCost(of: described(propertyBase + String(repeating: "ignored", count: 1_000))))
    }

    func testProjectionRetainsPropertiesNamedLikeSchemaMetadata() throws {
        let json = #"{"type":"object","properties":{"description":{"type":"string","description":"User value"},"title":{"type":"integer"}},"required":["description"]}"#
        let projected = try XCTUnwrap(ActionToolSchema.projected(json, toolName: "test"))
        let properties = try XCTUnwrap(projected["properties"] as? [String: [String: Any]])
        XCTAssertEqual(Set(properties.keys), ["description", "title"])
        XCTAssertEqual(properties["description"]?["description"] as? String, "User value")
        XCTAssertEqual(projected["required"] as? [String], ["description"])
    }
}

enum CuaToolRankingFixture {
    private struct Document: Decodable {
        struct Tool: Decodable { let name: String; let description: String }
        let tools: [Tool]
    }

    static func tools() throws -> [ActionToolSpec] {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/cua-driver-0.28.2-tools.json")
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: file))
        let server = UUID()
        return document.tools.map { tool in
            ActionToolSpec(descriptor: MCPToolDescriptor(serverID: server, serverName: "cua-driver", name: tool.name,
                title: nil, description: tool.description, risk: .mutating, inputSchemaJSON: "{}"))
        }
    }
}
