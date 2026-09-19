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

    func testRedactsNativeLabelsValuesAndCapabilities() {
        let json = #"{"text":"private entry","value":"private value","label":"private label","element_token":"s00000001:2","window_id":42}"#
        let redacted = ActionRedactor.redact(json)
        XCTAssertFalse(redacted.contains("private"))
        XCTAssertFalse(redacted.contains("s00000001:2"))
        XCTAssertTrue(redacted.contains("42"))
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

    func testOrdinaryTitlesAndQueriesRemainUsefulInGenericAuditArguments() throws {
        let json = #"{"title":"Cloudflare DNS","query":"catacolabs.com","nested":[{"TITLE":"Password policy","Query":"token counts"}],"text":"private entry"}"#
        let output = ActionRedactor.redact(json)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(object["title"] as? String, "Cloudflare DNS")
        XCTAssertEqual(object["query"] as? String, "catacolabs.com")
        XCTAssertTrue(output.contains("Password policy"))
        XCTAssertTrue(output.contains("token counts"))
        XCTAssertFalse(output.contains("private entry"))
    }

    func testRetainedFieldsAndStringArraysStillMaskInlineSecrets() throws {
        let json = #"{"title":"Bearer abc+/~==","query":"password=\"two word secret\"","other":["api_key=inline-secret","ordinary"],"url":"https://example.com/?token=url-secret&limit=3"}"#
        let output = ActionRedactor.redact(json)
        for secret in ["abc", "two word secret", "inline-secret", "url-secret"] { XCTAssertFalse(output.contains(secret), output) }
        XCTAssertTrue(output.contains("ordinary"))
        XCTAssertTrue(output.contains("limit=3"))
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(output.utf8)))
    }

    func testQuotedAndIncompleteSecretValuesDoNotLeak() {
        for text in [#"{"password":"two word secret"}"#, "token='two word secret'", "password=\"two word secret",
                     "secret: “two word secret”", "Authorization: Bearer abc+/~=="] {
            let output = ActionRedactor.redactText(text)
            XCTAssertFalse(output.contains("two word secret"), output)
            XCTAssertFalse(output.contains("abc"), output)
        }
    }
}
