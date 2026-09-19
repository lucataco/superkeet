import XCTest
@testable import Superkeet

final class ObservationProjectionTests: XCTestCase {
    private func notesJSON() throws -> String {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/cua-driver-0.28.2-notes-window-state.json")
        return try String(contentsOf: file, encoding: .utf8)
    }

    private func focus(_ text: String) -> Set<String> { HeuristicIntentExtractor.intent(for: text).routingTerms }

    func testNewNoteStepSurfacesTheToolbarButtonAndFileMenuItemFirst() throws {
        let text = try XCTUnwrap(ObservationProjection.compact(json: notesJSON(), focus: focus("create a new note")))
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "Notes (snapshot s00000003, 80 elements; use element_index or element_token)")
        XCTAssertTrue(lines[1].hasPrefix("[184] Button “New Note”"), lines[1])
        XCTAssertTrue(lines[2].hasPrefix("[290] MenuItem File ▸ “New Note”"), lines[2])
        XCTAssertLessThanOrEqual(text.count, ObservationProjection.defaultLimit)
        XCTAssertFalse(text.contains("LLM prompts"), "The note body is never included.")
        XCTAssertTrue(text.contains("[174] TextArea = (201 characters)"), "Only the size of a text body is reported.")
        XCTAssertFalse(text.contains("ICMNoteListCell"), "Internal identifiers are dropped.")
        XCTAssertFalse(text.contains("unlocalized"))
        XCTAssertFalse(text.contains("Import Markdown"), "Menu items that do not match the step are folded away.")
    }

    func testUnfocusedStepListsActionableControlsInDocumentOrderWithoutMenus() throws {
        let text = try XCTUnwrap(ObservationProjection.compact(json: notesJSON(), focus: []))
        XCTAssertTrue(text.contains("[182] Button “Toggle sidebar”"))
        XCTAssertTrue(text.contains("[184] Button “New Note”"))
        XCTAssertTrue(text.contains("[190] Button “Share”"))
        XCTAssertFalse(text.contains("MenuItem"), "Without a matching term, the menu bar is noise.")
        XCTAssertTrue(text.contains("[174] TextArea"), "Text fields are listed so the model can target them.")
        XCTAssertFalse(text.contains("Complete the objective"), "…but their long values are not.")
        XCTAssertLessThanOrEqual(text.count, ObservationProjection.defaultLimit)
        let buttons = text.split(separator: "\n").filter { $0.contains("Button") }.compactMap { line -> Int? in
            Int(line.dropFirst().prefix { $0.isNumber })
        }
        XCTAssertEqual(buttons, buttons.sorted(), "Equal scores keep document order.")
    }

    func testExportStepRanksMatchingMenuItemsAbovePlainButtons() throws {
        let text = try XCTUnwrap(ObservationProjection.compact(json: notesJSON(), focus: focus("export to markdown")))
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[1].contains("MenuItem File ▸ Export To ▸ “Markdown”"), "Two matching words rank first: \(lines[1])")
        XCTAssertTrue(lines[2...3].contains { $0.contains("MenuItem File ▸ “Export To”") }, text)
        XCTAssertTrue(lines[2...3].contains { $0.contains("MenuItem File ▸ “Import Markdown...”") }, text)
        XCTAssertTrue(lines[4].hasPrefix("[175] Link"), "Buttons and links follow the matching menu items.")
    }

    func testTinyLimitStillReturnsHeaderAndCount() throws {
        let text = try XCTUnwrap(ObservationProjection.compact(json: notesJSON(), focus: focus("create a new note"), limit: 120))
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[0].hasPrefix("Notes (snapshot"))
        XCTAssertTrue(lines.last?.contains("more elements not shown") == true, text)
        XCTAssertLessThanOrEqual(text.count, 160)
    }

    func testWindowListIsOnScreenFirstThenMatchingThenFrontmost() throws {
        let json = #"""
        {"current_space_id":28,"windows":[
          {"app_name":"Google Chrome","pid":1285,"window_id":68,"title":"Home / X","is_on_screen":true,"layer":0,"z_index":5},
          {"app_name":"Notes","pid":45613,"window_id":652,"title":"","is_on_screen":false,"layer":0,"z_index":null},
          {"app_name":"Notes","pid":45613,"window_id":651,"title":"Notes","is_on_screen":true,"layer":0,"z_index":1},
          {"app_name":"Ghostty","pid":1332,"window_id":96,"title":"OC | Actions mode multi-step workflows","is_on_screen":true,"layer":0,"z_index":3}
        ]}
        """#
        let text = try XCTUnwrap(ObservationProjection.compact(json: json, focus: focus("create a new note in Notes")))
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "4 windows (pid, window_id, app, title; on-screen first):")
        XCTAssertEqual(lines[1], "pid 45613 window 651 Notes")
        XCTAssertEqual(lines[2], "pid 1285 window 68 Google Chrome “Home / X”")
        XCTAssertEqual(lines[3], "pid 1332 window 96 Ghostty “OC | Actions mode multi-step workflows”")
        XCTAssertEqual(lines[4], "pid 45613 window 652 Notes (off screen)")
    }

    func testAppListPrefersMatchingThenRunningApps() throws {
        let json = #"""
        {"apps":[
          {"name":"Pages","bundle_id":"com.apple.iWork.Pages","running":false,"pid":0},
          {"name":"Notes","bundle_id":"com.apple.Notes","running":true,"active":true,"pid":45613},
          {"name":"Discord","bundle_id":"com.hnc.Discord","running":true,"pid":800}
        ]}
        """#
        let text = try XCTUnwrap(ObservationProjection.compact(json: json, focus: focus("open Discord")))
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[1], "Discord com.hnc.Discord running pid 800")
        XCTAssertEqual(lines[2], "Notes com.apple.Notes running pid 45613 (frontmost)")
        XCTAssertEqual(lines[3], "Pages com.apple.iWork.Pages")
    }

    func testUnknownShapesAndNonJSONReturnNil() {
        XCTAssertNil(ObservationProjection.compact(json: "plain text result", focus: []))
        XCTAssertNil(ObservationProjection.compact(json: #"{"status":"ok","effect":"confirmed"}"#, focus: []))
        XCTAssertNil(ObservationProjection.compact(json: "[1,2,3]", focus: []))
    }

    func testInternalIdentifierHeuristics() {
        for label in ["_NS:322", "ICMNoteListCell, Note[id=AA90]", "<<Import From Device - unlocalized>>", "NSToolbarItemViewerCell"] {
            XCTAssertTrue(ObservationProjection.isInternalIdentifier(label), label)
        }
        for label in ["New Note", "File", "Toggle sidebar", "September 12, 2026 at 1:30 PM", "https://example.com"] {
            XCTAssertFalse(ObservationProjection.isInternalIdentifier(label), label)
        }
    }

    func testFocusTermsDropStopwordsAndShortWords() {
        XCTAssertEqual(ObservationProjection.focusTerms(focus("create a new note")), ["note"])
        XCTAssertEqual(ObservationProjection.focusTerms(["Export", "to", "PDF", "it"]), ["export", "pdf"])
    }
}
