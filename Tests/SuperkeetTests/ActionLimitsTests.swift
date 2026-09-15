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
}
