import XCTest
@testable import Superkeet

final class ActionArgumentNormalizerTests: XCTestCase {
    private func normalized(_ arguments: String, schema: String) -> [String: Any] {
        let output = ActionArgumentNormalizer.normalize(argumentsJSON: arguments, schemaJSON: schema)
        let data = Data(output.utf8)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private let urlSchema = #"{"type":"object","properties":{"url":{"type":"string"},"timeout":{"type":"integer"}}}"#

    func testAddsSchemeToBareDomain() {
        let result = normalized(#"{"url":"youtube.com"}"#, schema: urlSchema)
        XCTAssertEqual(result["url"] as? String, "https://youtube.com")
    }

    func testPreservesPathAndQuery() {
        let result = normalized(#"{"url":"youtube.com/watch?v=abc123"}"#, schema: urlSchema)
        XCTAssertEqual(result["url"] as? String, "https://youtube.com/watch?v=abc123")
    }

    func testLeavesFullyQualifiedURLUntouched() {
        let result = normalized(#"{"url":"http://example.com/a"}"#, schema: urlSchema)
        XCTAssertEqual(result["url"] as? String, "http://example.com/a")
    }

    func testDoesNotModifyNonURLProperties() {
        let schema = #"{"type":"object","properties":{"text":{"type":"string"}}}"#
        let result = normalized(#"{"text":"youtube.com"}"#, schema: schema)
        XCTAssertEqual(result["text"] as? String, "youtube.com")
    }

    func testMatchesCommonURLPropertyNames() {
        for name in ["url", "pageUrl", "href", "uri", "targetURL"] {
            XCTAssertTrue(ActionArgumentNormalizer.isURLPropertyName(name), "\(name) should be a URL property")
        }
        for name in ["text", "command_line", "element_index", "count"] {
            XCTAssertFalse(ActionArgumentNormalizer.isURLPropertyName(name), "\(name) should not be a URL property")
        }
    }

    func testSkipsLocalPathsAndSchemes() {
        XCTAssertNil(ActionArgumentNormalizer.normalizedURL("/tmp/file.html"))
        XCTAssertNil(ActionArgumentNormalizer.normalizedURL("./relative.html"))
        XCTAssertNil(ActionArgumentNormalizer.normalizedURL("mailto:me@example.com"))
        XCTAssertNil(ActionArgumentNormalizer.normalizedURL("https://already.com"))
        XCTAssertNil(ActionArgumentNormalizer.normalizedURL("localhost:8080"))
    }

    func testPreservesOtherArguments() {
        let result = normalized(#"{"url":"example.com","timeout":30}"#, schema: urlSchema)
        XCTAssertEqual(result["url"] as? String, "https://example.com")
        XCTAssertEqual(result["timeout"] as? Int, 30)
    }

    func testReturnsOriginalWhenNothingToFix() {
        let original = #"{"url":"https://example.com"}"#
        XCTAssertEqual(ActionArgumentNormalizer.normalize(argumentsJSON: original, schemaJSON: urlSchema), original)
    }
}
