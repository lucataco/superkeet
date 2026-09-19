import Carbon.HIToolbox
import XCTest
@testable import Superkeet

final class KeyboardShortcutTests: XCTestCase {
    func testParsesModifiersAndKeyInAnyOrderAndSpelling() throws {
        let chord = try XCTUnwrap(KeyboardShortcut(keys: ["Shift", "CMD", "z"]))
        XCTAssertEqual(chord.modifiers, [.command, .shift])
        XCTAssertEqual(chord.key, "z")
        XCTAssertEqual(chord.keyCode, CGKeyCode(kVK_ANSI_Z))
        XCTAssertEqual(chord.displayName, "⇧⌘Z")
        XCTAssertEqual(chord.keys, ["shift", "cmd", "z"])
        XCTAssertTrue(chord.flags.contains(.maskCommand))
        XCTAssertTrue(chord.flags.contains(.maskShift))
        XCTAssertFalse(chord.flags.contains(.maskAlternate))

        XCTAssertEqual(KeyboardShortcut(keys: ["command", "N"])?.displayName, "⌘N")
        XCTAssertEqual(KeyboardShortcut(keys: ["⌘", "n"]), KeyboardShortcut(keys: ["cmd", "n"]))
        XCTAssertEqual(KeyboardShortcut(keys: ["ctrl", "alt", "delete"])?.displayName, "⌃⌥Delete")
        XCTAssertEqual(KeyboardShortcut(keys: ["cmd", "enter"])?.key, "return")
        XCTAssertEqual(KeyboardShortcut(keys: ["cmd", "1"])?.keyCode, CGKeyCode(kVK_ANSI_1))
        XCTAssertEqual(KeyboardShortcut(keys: ["option", "f5"])?.keyCode, CGKeyCode(kVK_F5))
    }

    func testNamedKeysMayStandAloneButLettersMayNot() {
        XCTAssertEqual(KeyboardShortcut(keys: ["return"])?.displayName, "Return")
        XCTAssertEqual(KeyboardShortcut(keys: ["escape"])?.keyCode, CGKeyCode(kVK_Escape))
        XCTAssertNil(KeyboardShortcut(keys: ["n"]), "A bare letter is typing, not a shortcut.")
        XCTAssertNil(KeyboardShortcut(keys: ["7"]))
    }

    func testRejectsUnknownKeysAndMalformedChords() {
        XCTAssertNil(KeyboardShortcut(keys: []))
        XCTAssertNil(KeyboardShortcut(keys: ["cmd"]), "A modifier alone is not a shortcut.")
        XCTAssertNil(KeyboardShortcut(keys: ["cmd", "n", "s"]), "Exactly one non-modifier key.")
        XCTAssertNil(KeyboardShortcut(keys: ["cmd", "power"]))
        XCTAssertNil(KeyboardShortcut(keys: ["cmd", "eject"]))
        XCTAssertNil(KeyboardShortcut(keys: ["hyper", "n"]))
    }

    func testRoundTripsThroughWireForm() throws {
        for keys in [["cmd", "n"], ["shift", "cmd", "z"], ["ctrl", "option", "shift", "cmd", "space"], ["return"], ["cmd", "t"]] {
            let chord = try XCTUnwrap(KeyboardShortcut(keys: keys), keys.joined())
            XCTAssertEqual(KeyboardShortcut(keys: chord.keys), chord)
        }
    }
}
