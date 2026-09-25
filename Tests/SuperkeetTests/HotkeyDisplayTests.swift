import XCTest
import CoreGraphics
@testable import Superkeet

final class HotkeyDisplayTests: XCTestCase {

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
        let flags = Int(
            CGEventFlags.maskControl.rawValue |
            CGEventFlags.maskAlternate.rawValue |
            CGEventFlags.maskShift.rawValue |
            CGEventFlags.maskCommand.rawValue
        )
        let result = displayNameForHotkey(keyCode: 15, modifierFlags: flags)
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

    func testPlainTypingKeysAreRejectedAsHotkeys() {
        for keyCode in [0, 49, 36, 48, 51, 123] { // A, Space, Return, Tab, Delete, Left
            XCTAssertFalse(hotkeyIsSafeToAssign(keyCode: keyCode, modifiers: 0), "keyCode \(keyCode)")
        }
    }

    func testShiftAloneIsNotEnough() {
        XCTAssertFalse(hotkeyIsSafeToAssign(keyCode: 0, modifiers: Int(CGEventFlags.maskShift.rawValue)))
        XCTAssertFalse(hotkeyIsSafeToAssign(keyCode: 49, modifiers: Int(CGEventFlags.maskShift.rawValue)))
    }

    func testCommandOptionOrControlMakesAnyKeySafe() {
        for mask in [CGEventFlags.maskCommand, .maskAlternate, .maskControl] {
            XCTAssertTrue(hotkeyIsSafeToAssign(keyCode: 49, modifiers: Int(mask.rawValue)))
        }
        let shiftOption = CGEventFlags.maskShift.rawValue | CGEventFlags.maskAlternate.rawValue
        XCTAssertTrue(hotkeyIsSafeToAssign(keyCode: 0, modifiers: Int(shiftOption)))
    }

    func testFnAndFunctionKeysAreAllowedWithoutModifiers() {
        for keyCode in [63, 122, 111, 105, 90] { // fn, F1, F12, F13, F20
            XCTAssertTrue(hotkeyIsSafeToAssign(keyCode: keyCode, modifiers: 0), "keyCode \(keyCode)")
        }
    }
}
