import AppKit
import XCTest
@testable import Superkeet

final class MenuKeyEquivalentTests: XCTestCase {
    func testTheDefaultShortcutsAreShownBesideTheirMenuItems() throws {
        let listen = try XCTUnwrap(MenuKeyEquivalent(keyCode: 49, modifierFlags: 655_360))
        XCTAssertEqual(listen.key, " ")
        XCTAssertEqual(listen.modifiers, [.option, .shift], "⌥⇧Space starts listening for actions.")

        let record = try XCTUnwrap(MenuKeyEquivalent(keyCode: 49, modifierFlags: 524_288))
        XCTAssertEqual(record.modifiers, [.option])
    }

    func testLettersAreLowercasedSoShiftIsNotImpliedTwice() throws {
        let shortcut = try XCTUnwrap(MenuKeyEquivalent(keyCode: 45, modifierFlags: 1_048_576 | 131_072))
        XCTAssertEqual(shortcut.key, "n")
        XCTAssertEqual(shortcut.modifiers, [.command, .shift])
    }

    func testAShortcutAMenuCannotDrawHasNoKeyEquivalent() {
        XCTAssertNil(MenuKeyEquivalent(keyCode: 63, modifierFlags: 0), "fn alone is push-to-talk.")
    }

    func testApplyingItSetsTheMenuItemsKeyAndModifiers() throws {
        let item = NSMenuItem(title: "Start Listening for Actions", action: nil, keyEquivalent: "")
        try XCTUnwrap(MenuKeyEquivalent(keyCode: 49, modifierFlags: 655_360)).apply(to: item)
        XCTAssertEqual(item.keyEquivalent, " ")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.option, .shift])
    }
}
