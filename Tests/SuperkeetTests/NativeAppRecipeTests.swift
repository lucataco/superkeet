import XCTest
@testable import Superkeet

final class NativeAppRecipeTests: XCTestCase {
    private func recipe(_ clause: String) -> (keys: String, target: NativeAppRecipe.Target, description: String)? {
        guard let recipe = NativeAppRecipe.recipe(for: clause) else { return nil }
        return (recipe.shortcut.displayName, recipe.target, recipe.description)
    }

    func testEveryRuleCompiled() {
        XCTAssertEqual(NativeAppRecipe.ruleCount, NativeAppRecipe.expectedRuleCount)
    }

    func testNewDocumentVerbsMapToCommandN() {
        for clause in ["create a new note", "Create a new note.", "make a new document", "start a new message", "compose a new email",
                       "add a new reminder", "write a new note", "open a new window", "new note", "please create a brand new note"] {
            let result = recipe(clause)
            XCTAssertEqual(result?.keys, "⌘N", clause)
            XCTAssertEqual(result?.target, .current, clause)
        }
        XCTAssertEqual(recipe("create a new note")?.description, "create a new note")
        XCTAssertEqual(recipe("make a new document")?.description, "create a new document")
        XCTAssertEqual(recipe("create a new one")?.description, "create a new item")
    }

    func testNewTabIsCommandT() {
        XCTAssertEqual(recipe("open a new tab")?.keys, "⌘T")
        XCTAssertEqual(recipe("new tab")?.keys, "⌘T")
        XCTAssertEqual(recipe("create a new tab in Safari")?.target, .named("safari"))
    }

    func testTrailingAppNamesBecomeTargets() {
        XCTAssertEqual(recipe("create a new note in Notes")?.target, .named("notes"))
        XCTAssertEqual(recipe("create a new note in the Notes app")?.target, .named("notes app"))
        XCTAssertEqual(recipe("save it in Pages")?.target, .named("pages"))
        XCTAssertEqual(recipe("undo that in TextEdit")?.target, .named("textedit"))
        XCTAssertEqual(recipe("create a new document using Pages")?.keys, "⌘N")
    }

    func testEditingVerbs() {
        XCTAssertEqual(recipe("save")?.keys, "⌘S")
        XCTAssertEqual(recipe("save it")?.keys, "⌘S")
        XCTAssertEqual(recipe("save the document")?.keys, "⌘S")
        XCTAssertEqual(recipe("close the window")?.keys, "⌘W")
        XCTAssertEqual(recipe("close this tab")?.keys, "⌘W")
        XCTAssertEqual(recipe("close it")?.keys, "⌘W")
        XCTAssertEqual(recipe("undo")?.keys, "⌘Z")
        XCTAssertEqual(recipe("undo the last change")?.keys, "⌘Z")
        XCTAssertEqual(recipe("redo that")?.keys, "⇧⌘Z")
        XCTAssertEqual(recipe("select all")?.keys, "⌘A")
        XCTAssertEqual(recipe("select all the text")?.keys, "⌘A")
    }

    func testQuitNamesTheAppDirectly() {
        XCTAssertEqual(recipe("quit")?.keys, "⌘Q")
        XCTAssertEqual(recipe("quit")?.target, .current)
        XCTAssertEqual(recipe("quit Safari")?.target, .named("safari"))
        XCTAssertEqual(recipe("quit the Notes app")?.target, .named("notes"))
        XCTAssertEqual(recipe("quit it")?.target, .current)
    }

    func testUnrelatedClausesHaveNoRecipe() {
        for clause in ["open Notes", "search for cats", "click Save", "type hello", "save the whales from extinction",
                       "create a note", "close friends", "undo button", "select the third row", "new", ""] {
            XCTAssertNil(NativeAppRecipe.recipe(for: clause), clause)
        }
        XCTAssertEqual(recipe("quit smoking today")?.target, .named("smoking today"))
    }
}
