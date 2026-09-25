import XCTest
@testable import Superkeet

final class TranscriptTextProcessorTests: XCTestCase {
    func testScopedWholePhraseReplacementsDoNotCascade() {
        let rules = [
            PhraseReplacement(phrase: "off middleware", replacement: "auth middleware"),
            PhraseReplacement(phrase: "off middleware", replacement: "AUTH middleware", bundleID: "editor"),
            PhraseReplacement(phrase: "auth middleware", replacement: "wrong")
        ]
        XCTAssertEqual(TranscriptTextProcessor.replacePhrases("Turn off middleware, not off switches", rules: rules, bundleID: "editor"), "Turn AUTH middleware, not off switches")
        XCTAssertEqual(TranscriptTextProcessor.replacePhrases("OFF middleware", rules: rules, bundleID: "other"), "auth middleware")
        XCTAssertEqual(TranscriptTextProcessor.replacePhrases("scoff middleware", rules: rules, bundleID: "other"), "scoff middleware")
    }

    func testLiteralReplacementMetacharactersAndUnicodeBoundaries() {
        let rules = [PhraseReplacement(phrase: "C++", replacement: "$1\\value")]
        XCTAssertEqual(TranscriptTextProcessor.replacePhrases("C++ and XC++", rules: rules, bundleID: ""), "$1\\value and XC++")
    }

    func testSpokenCommandsAreOptInAndNeverInferFromOr() {
        let raw = "Orange or yellow. Er, orange. Scratch that."
        XCTAssertEqual(TranscriptTextProcessor.process(raw, removeFillers: false, replacements: [], bundleID: "", spokenCommands: false), raw)
        XCTAssertEqual(TranscriptTextProcessor.applySpokenCommands(raw), "Orange or yellow. Er,")
    }

    func testExplicitReplacementAndUndo() {
        XCTAssertEqual(TranscriptTextProcessor.applySpokenCommands("Choose orange, scratch that, choose yellow."), "choose yellow.")
        XCTAssertEqual(TranscriptTextProcessor.applySpokenCommands("Choose orange, replace orange with yellow."), "Choose yellow,")
        XCTAssertEqual(TranscriptTextProcessor.applySpokenCommands("Choose orange. Replace orange with yellow."), "Choose yellow.")
        XCTAssertEqual(TranscriptTextProcessor.applySpokenCommands("Choose orange. Replace orange with yellow. Undo last correction."), "Choose orange.")
        XCTAssertEqual(TranscriptTextProcessor.applySpokenCommands("Keep this. Remove this. Scratch that. Undo last correction."), "Keep this. Remove this.")
    }

    func testAmbiguousOrQuotedCommandsStayLiteral() {
        for text in ["Orange and orange. Replace orange with yellow.", "We should scratch that later.", "Say ‘scratch that’.", "\n...A A agreed agreed!\n", "Replace missing with yellow."] {
            XCTAssertEqual(TranscriptTextProcessor.applySpokenCommands(text), text)
        }
    }

    func testIncompleteReplacementCommandsStayLiteralWithoutCrashing() {
        for command in ["Replace with yellow.", "replace with with yellow.", "Replace orange with.", "Replace  with yellow.", "Replace orange with   .", "Replace.", "Replace orange."] {
            let text = "Orange is the color. " + command
            XCTAssertEqual(TranscriptTextProcessor.applySpokenCommands(text), text)
        }
        XCTAssertEqual(TranscriptTextProcessor.applySpokenCommands("Choose 橙色. Replace 橙色 with 黄色."), "Choose 黄色.")
    }

    func testLegacyHistoryDecodesWithoutRecoveryFields() throws {
        let record = TranscriptionRecord(text: "original", durationSeconds: 2, activeAppName: "Editor", activeAppBundleId: "editor")
        let bytes = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(TranscriptionRecord.self, from: bytes)
        XCTAssertNil(decoded.rawText)
        XCTAssertNil(decoded.isPartial)
        let recovered = TranscriptionRecord(text: "changed", durationSeconds: 2, activeAppName: "Editor", activeAppBundleId: "editor", rawText: "original", isPartial: true)
        let roundTrip = try JSONDecoder().decode(TranscriptionRecord.self, from: JSONEncoder().encode(recovered))
        XCTAssertEqual(roundTrip.rawText, "original")
        XCTAssertEqual(roundTrip.isPartial, true)
    }

    func testPhraseStorePersistsWithIsolatedURL() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("rules.json")
        let store = PhraseReplacementStore(fileURL: url)
        let rules = [PhraseReplacement(phrase: "off middleware", replacement: "auth middleware", bundleID: "editor")]
        store.save(rules)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(PhraseReplacementStore(fileURL: url).rules, rules)
    }

    func testPhraseStorePreservesUnreadableFileBeforeOverwriting() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("rules.json")
        let original = Data("{ not valid json".utf8)
        try original.write(to: url)

        let store = PhraseReplacementStore(fileURL: url)
        XCTAssertTrue(store.rules.isEmpty)
        XCTAssertNotNil(store.errorMessage)

        let rules = [PhraseReplacement(phrase: "a", replacement: "b")]
        store.save(rules)

        let backup = try XCTUnwrap(store.recoveryBackupURL)
        XCTAssertEqual(try Data(contentsOf: backup), original, "Unreadable file must be preserved byte-for-byte.")
        XCTAssertEqual(PhraseReplacementStore(fileURL: url).rules, rules)
    }

    func testPhraseReplacementDecodesWithMissingOptionalFields() throws {
        let json = Data(#"[{"phrase":"teh","replacement":"the"}]"#.utf8)
        let decoded = try JSONDecoder().decode([PhraseReplacement].self, from: json)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.phrase, "teh")
        XCTAssertEqual(decoded.first?.replacement, "the")
        XCTAssertEqual(decoded.first?.bundleID, "")
    }

    func testPhraseReplacementDecodingIgnoresUnknownFields() throws {
        let id = UUID()
        let json = Data(#"[{"id":"\#(id.uuidString)","phrase":"x","replacement":"y","bundleID":"app","futureField":true}]"#.utf8)
        let decoded = try JSONDecoder().decode([PhraseReplacement].self, from: json)
        XCTAssertEqual(decoded, [PhraseReplacement(id: id, phrase: "x", replacement: "y", bundleID: "app")])
    }
}
