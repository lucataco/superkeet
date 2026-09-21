import XCTest
import CoreGraphics
@testable import Superkeet

final class ModifierMatchingTests: XCTestCase {

    func testNoModifiersRequiredMatchesWhenNonePressed() {
        let flags = CGEventFlags(rawValue: 0)
        XCTAssertTrue(HotkeyDecider.modifiersMatch(flags, required: 0))
    }

    func testNoModifiersRequiredFailsWhenCommandPressed() {
        XCTAssertFalse(HotkeyDecider.modifiersMatch(.maskCommand, required: 0))
    }

    func testNoModifiersRequiredFailsWhenOptionPressed() {
        XCTAssertFalse(HotkeyDecider.modifiersMatch(.maskAlternate, required: 0))
    }

    func testNoModifiersRequiredFailsWhenControlPressed() {
        XCTAssertFalse(HotkeyDecider.modifiersMatch(.maskControl, required: 0))
    }

    func testNoModifiersRequiredFailsWhenShiftPressed() {
        XCTAssertFalse(HotkeyDecider.modifiersMatch(.maskShift, required: 0))
    }

    func testNoModifiersRequiredIgnoresNonSignificantFlags() {
        let flags = CGEventFlags(rawValue: CGEventFlags.maskNumericPad.rawValue | CGEventFlags.maskSecondaryFn.rawValue)
        XCTAssertTrue(HotkeyDecider.modifiersMatch(flags, required: 0))
    }

    func testSingleModifierOptionMatches() {
        let required = Int(CGEventFlags.maskAlternate.rawValue)
        XCTAssertTrue(HotkeyDecider.modifiersMatch(.maskAlternate, required: required))
    }

    func testSingleModifierOptionFailsWhenCommandPressed() {
        let required = Int(CGEventFlags.maskAlternate.rawValue)
        XCTAssertFalse(HotkeyDecider.modifiersMatch(.maskCommand, required: required))
    }

    func testSingleModifierCommandMatches() {
        let required = Int(CGEventFlags.maskCommand.rawValue)
        XCTAssertTrue(HotkeyDecider.modifiersMatch(.maskCommand, required: required))
    }

    func testMultipleModifiersAllPresent() {
        let required = Int(CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue)
        let eventFlags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue)
        XCTAssertTrue(HotkeyDecider.modifiersMatch(eventFlags, required: required))
    }

    func testMultipleModifiersSubsetPresent() {
        let required = Int(CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue)
        XCTAssertFalse(HotkeyDecider.modifiersMatch(.maskCommand, required: required))
    }

    func testMultipleModifiersExtraModifierPresent() {
        let required = Int(CGEventFlags.maskCommand.rawValue)
        let eventFlags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue)
        XCTAssertFalse(HotkeyDecider.modifiersMatch(eventFlags, required: required))
    }

    func testExtraNonSignificantFlagsIgnored() {
        let required = Int(CGEventFlags.maskAlternate.rawValue)
        let eventFlags = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskNumericPad.rawValue)
        XCTAssertTrue(HotkeyDecider.modifiersMatch(eventFlags, required: required))
    }
}
