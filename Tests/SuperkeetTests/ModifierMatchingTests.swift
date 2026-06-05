import XCTest
import CoreGraphics
@testable import Superkeet

final class ModifierMatchingTests: XCTestCase {

    // MARK: - required == 0 (no modifiers required)

    func testNoModifiersRequiredMatchesWhenNonePressed() {
        let flags = CGEventFlags(rawValue: 0)
        XCTAssertTrue(HotkeyManager.modifiersMatch(flags, required: 0))
    }

    func testNoModifiersRequiredFailsWhenCommandPressed() {
        XCTAssertFalse(HotkeyManager.modifiersMatch(.maskCommand, required: 0))
    }

    func testNoModifiersRequiredFailsWhenOptionPressed() {
        XCTAssertFalse(HotkeyManager.modifiersMatch(.maskAlternate, required: 0))
    }

    func testNoModifiersRequiredFailsWhenControlPressed() {
        XCTAssertFalse(HotkeyManager.modifiersMatch(.maskControl, required: 0))
    }

    func testNoModifiersRequiredFailsWhenShiftPressed() {
        XCTAssertFalse(HotkeyManager.modifiersMatch(.maskShift, required: 0))
    }

    func testNoModifiersRequiredIgnoresNonSignificantFlags() {
        // NumericPad and SecondaryFn are non-significant — should still match when required == 0
        let flags = CGEventFlags(rawValue: CGEventFlags.maskNumericPad.rawValue | CGEventFlags.maskSecondaryFn.rawValue)
        XCTAssertTrue(HotkeyManager.modifiersMatch(flags, required: 0))
    }

    // MARK: - Single modifier required

    func testSingleModifierOptionMatches() {
        let required = Int(CGEventFlags.maskAlternate.rawValue)
        XCTAssertTrue(HotkeyManager.modifiersMatch(.maskAlternate, required: required))
    }

    func testSingleModifierOptionFailsWhenCommandPressed() {
        let required = Int(CGEventFlags.maskAlternate.rawValue)
        XCTAssertFalse(HotkeyManager.modifiersMatch(.maskCommand, required: required))
    }

    func testSingleModifierCommandMatches() {
        let required = Int(CGEventFlags.maskCommand.rawValue)
        XCTAssertTrue(HotkeyManager.modifiersMatch(.maskCommand, required: required))
    }

    // MARK: - Multiple modifiers required

    func testMultipleModifiersAllPresent() {
        let required = Int(CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue)
        let eventFlags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue)
        XCTAssertTrue(HotkeyManager.modifiersMatch(eventFlags, required: required))
    }

    func testMultipleModifiersSubsetPresent() {
        let required = Int(CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue)
        // Only Command pressed, missing Shift
        XCTAssertFalse(HotkeyManager.modifiersMatch(.maskCommand, required: required))
    }

    func testMultipleModifiersExtraModifierPresent() {
        let required = Int(CGEventFlags.maskCommand.rawValue)
        // Command + Shift pressed, but only Command required — should fail because extra significant modifier
        let eventFlags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue)
        XCTAssertFalse(HotkeyManager.modifiersMatch(eventFlags, required: required))
    }

    // MARK: - Non-significant flags are ignored

    func testExtraNonSignificantFlagsIgnored() {
        let required = Int(CGEventFlags.maskAlternate.rawValue)
        // Option + NumericPad — NumericPad should be ignored
        let eventFlags = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskNumericPad.rawValue)
        XCTAssertTrue(HotkeyManager.modifiersMatch(eventFlags, required: required))
    }
}
