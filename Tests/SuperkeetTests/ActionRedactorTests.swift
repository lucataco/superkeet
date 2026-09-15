import XCTest
@testable import Superkeet

final class ActionRedactorTests: XCTestCase {
    func testRedactsSensitiveKeys() {
        let json = #"{"query":"hello","apiKey":"secret-value","nested":{"password":"hunter2"}}"#
        let redacted = ActionRedactor.redact(json)
        XCTAssertFalse(redacted.contains("secret-value"))
        XCTAssertFalse(redacted.contains("hunter2"))
        XCTAssertTrue(redacted.contains("hello"))
    }

    func testRedactsCaseInsensitivelyAndWithHyphens() {
        let json = #"{"Authorization":"Bearer abc","session-token":"xyz"}"#
        let redacted = ActionRedactor.redact(json)
        XCTAssertFalse(redacted.contains("Bearer abc"))
        XCTAssertFalse(redacted.contains("xyz"))
    }

    func testLeavesNonSensitiveArgumentsUntouched() {
        let json = #"{"url":"https://example.com","count":3}"#
        let redacted = ActionRedactor.redact(json)
        XCTAssertTrue(redacted.contains("example.com"))
        XCTAssertTrue(redacted.contains("3"))
    }

    func testInvalidJSONWithPlainTextIsReturnedUnchanged() {
        XCTAssertEqual(ActionRedactor.redact("not json"), "not json")
    }

    func testInvalidJSONStillRedactsKeyValueSecrets() {
        let redacted = ActionRedactor.redact("command api_key=supersecret token: xyz")
        XCTAssertFalse(redacted.contains("supersecret"))
        XCTAssertFalse(redacted.contains("xyz"))
    }

    func testInvalidJSONStillRedactsBearerTokens() {
        let redacted = ActionRedactor.redact("Authorization: Bearer abc123.def-456")
        XCTAssertFalse(redacted.contains("abc123.def-456"))
    }

    func testTruncateReturnsShortTextUnchanged() {
        XCTAssertEqual(ActionResultText.truncate("hello", limit: 10), "hello")
    }

    func testTruncateMarksOmittedCharacters() {
        let result = ActionResultText.truncate("abcdefghij", limit: 4)
        XCTAssertTrue(result.hasPrefix("abcd"))
        XCTAssertTrue(result.contains("6 characters omitted"))
    }

    func testRedactTextMasksBearerTokens() {
        let text = ActionRedactor.redactText("Authorization: Bearer abc123.def-456")
        XCTAssertFalse(text.contains("abc123.def-456"))
        XCTAssertTrue(text.contains("***"))
    }

    func testRedactTextMasksKeyValueSecrets() {
        let text = ActionRedactor.redactText("api_key=supersecret token: xyz")
        XCTAssertFalse(text.contains("supersecret"))
        XCTAssertFalse(text.contains("xyz"))
    }

    func testRedactTextLeavesOrdinaryText() {
        XCTAssertEqual(ActionRedactor.redactText("opened the page successfully"), "opened the page successfully")
    }
}
