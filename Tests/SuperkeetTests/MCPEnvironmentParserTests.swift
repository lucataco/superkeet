import XCTest
@testable import Superkeet

final class MCPEnvironmentParserTests: XCTestCase {
    func testParsesKeyValueLines() {
        let parsed = MCPEnvironmentParser.parse("TOKEN=abc\nREGION=us-east-1")
        XCTAssertEqual(parsed, ["TOKEN": "abc", "REGION": "us-east-1"])
    }

    func testTrimsWhitespace() {
        let parsed = MCPEnvironmentParser.parse("  API_KEY = secret  ")
        XCTAssertEqual(parsed, ["API_KEY": "secret"])
    }

    func testKeepsEqualsSignsInValue() {
        let parsed = MCPEnvironmentParser.parse("CONNECTION=host=localhost;port=5432")
        XCTAssertEqual(parsed, ["CONNECTION": "host=localhost;port=5432"])
    }

    func testIgnoresBlankAndMalformedLines() {
        let parsed = MCPEnvironmentParser.parse("\nNO_VALUE\n=missing\nOK=1\n")
        XCTAssertEqual(parsed, ["OK": "1"])
    }
}
