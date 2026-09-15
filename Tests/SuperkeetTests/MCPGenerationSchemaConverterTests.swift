import XCTest
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

    func testToolBridgeDescriptionIsShortAndOmitsSchema() {
        let descriptor = MCPToolDescriptor(
            serverID: UUID(),
            serverName: "test",
            name: "click",
            title: nil,
            description: "Click an element by index or pixel coordinates from screenshot.",
            risk: .mutating,
            inputSchemaJSON: #"{"type":"object","properties":{"element_index":{"type":"string","description":"The uid of an element"}}}"#
        )
        let bridge = MCPToolBridge(spec: ActionToolSpec(descriptor: descriptor), execute: { _, _ in "" })
        let described = String(describing: bridge)
        XCTAssertFalse(described.contains("inputSchemaJSON"))
        XCTAssertFalse(described.contains("properties"))
        XCTAssertLessThanOrEqual(described.count, 140)
    }
}
