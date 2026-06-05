import XCTest
import CoreGraphics
@testable import Superkeet

final class HotkeyDisplayTests: XCTestCase {

    // MARK: - keyCodeName

    func testLetterKeyCodes() {
        XCTAssertEqual(keyCodeName(0), "A")
        XCTAssertEqual(keyCodeName(1), "S")
        XCTAssertEqual(keyCodeName(2), "D")
        XCTAssertEqual(keyCodeName(3), "F")
        XCTAssertEqual(keyCodeName(13), "W")
        XCTAssertEqual(keyCodeName(14), "E")
        XCTAssertEqual(keyCodeName(15), "R")
    }

    func testSpecialKeyCodes() {
        XCTAssertEqual(keyCodeName(36), "Return")
        XCTAssertEqual(keyCodeName(48), "Tab")
        XCTAssertEqual(keyCodeName(49), "Space")
        XCTAssertEqual(keyCodeName(51), "Delete")
        XCTAssertEqual(keyCodeName(53), "Escape")
        XCTAssertEqual(keyCodeName(63), "fn")
        XCTAssertEqual(keyCodeName(76), "Enter")
    }

    func testFunctionKeyCodes() {
        XCTAssertEqual(keyCodeName(122), "F1")
        XCTAssertEqual(keyCodeName(120), "F2")
        XCTAssertEqual(keyCodeName(99), "F3")
        XCTAssertEqual(keyCodeName(118), "F4")
        XCTAssertEqual(keyCodeName(96), "F5")
        XCTAssertEqual(keyCodeName(111), "F12")
    }

    func testArrowKeyCodes() {
        XCTAssertEqual(keyCodeName(123), "Left")
        XCTAssertEqual(keyCodeName(124), "Right")
        XCTAssertEqual(keyCodeName(125), "Down")
        XCTAssertEqual(keyCodeName(126), "Up")
    }

    func testUnknownKeyCodeFallback() {
        XCTAssertEqual(keyCodeName(200), "Key200")
        XCTAssertEqual(keyCodeName(999), "Key999")
    }

    // MARK: - displayNameForHotkey

    func testNoModifiers() {
        let result = displayNameForHotkey(keyCode: 49, modifierFlags: 0)
        XCTAssertEqual(result, "Space")
    }

    func testSingleModifierOption() {
        let optionFlag = Int(CGEventFlags.maskAlternate.rawValue)
        let result = displayNameForHotkey(keyCode: 49, modifierFlags: optionFlag)
        XCTAssertEqual(result, "⌥ Space")
    }

    func testSingleModifierCommand() {
        let cmdFlag = Int(CGEventFlags.maskCommand.rawValue)
        let result = displayNameForHotkey(keyCode: 49, modifierFlags: cmdFlag)
        XCTAssertEqual(result, "⌘ Space")
    }

    func testMultipleModifiersInCorrectOrder() {
        // Control + Option + Shift + Command
        let flags = Int(
            CGEventFlags.maskControl.rawValue |
            CGEventFlags.maskAlternate.rawValue |
            CGEventFlags.maskShift.rawValue |
            CGEventFlags.maskCommand.rawValue
        )
        let result = displayNameForHotkey(keyCode: 15, modifierFlags: flags)
        // Expected order: ⌃ ⌥ ⇧ ⌘ R
        XCTAssertEqual(result, "⌃ ⌥ ⇧ ⌘ R")
    }

    func testControlShiftCombo() {
        let flags = Int(
            CGEventFlags.maskControl.rawValue |
            CGEventFlags.maskShift.rawValue
        )
        let result = displayNameForHotkey(keyCode: 0, modifierFlags: flags)
        XCTAssertEqual(result, "⌃ ⇧ A")
    }

    func testFnKeyNoModifiers() {
        let result = displayNameForHotkey(keyCode: 63, modifierFlags: 0)
        XCTAssertEqual(result, "fn")
    }

    func testHotkeyAssignmentsConflictWhenKeyAndModifiersMatch() {
        XCTAssertTrue(hotkeyAssignmentsConflict(
            firstKeyCode: 49,
            firstModifiers: Int(CGEventFlags.maskAlternate.rawValue),
            secondKeyCode: 49,
            secondModifiers: Int(CGEventFlags.maskAlternate.rawValue)
        ))
    }

    func testHotkeyAssignmentsDoNotConflictWhenModifiersDiffer() {
        XCTAssertFalse(hotkeyAssignmentsConflict(
            firstKeyCode: 49,
            firstModifiers: Int(CGEventFlags.maskAlternate.rawValue),
            secondKeyCode: 49,
            secondModifiers: Int(CGEventFlags.maskControl.rawValue)
        ))
    }
}
