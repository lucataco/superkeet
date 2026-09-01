import XCTest
@testable import Superkeet

final class PTTHotkeyPolicyTests: XCTestCase {
    func testMatchingKeyDownStarts() {
        XCTAssertEqual(
            PTTHotkeyPolicy.keyAction(isKeyDown: true, pttAlreadyDown: false, modifiersMatch: true),
            .start
        )
    }

    func testMismatchedKeyDownIsIgnored() {
        XCTAssertEqual(
            PTTHotkeyPolicy.keyAction(isKeyDown: true, pttAlreadyDown: false, modifiersMatch: false),
            .ignore
        )
    }

    func testRepeatKeyDownIsConsumed() {
        XCTAssertEqual(
            PTTHotkeyPolicy.keyAction(isKeyDown: true, pttAlreadyDown: true, modifiersMatch: true),
            .consumeRepeat
        )
        XCTAssertEqual(
            PTTHotkeyPolicy.keyAction(isKeyDown: true, pttAlreadyDown: true, modifiersMatch: false),
            .consumeRepeat
        )
    }

    func testKeyUpStopsWhenHeld() {
        XCTAssertEqual(
            PTTHotkeyPolicy.keyAction(isKeyDown: false, pttAlreadyDown: true, modifiersMatch: true),
            .stop
        )
    }

    func testKeyUpIgnoredWhenNotHeld() {
        XCTAssertEqual(
            PTTHotkeyPolicy.keyAction(isKeyDown: false, pttAlreadyDown: false, modifiersMatch: true),
            .ignore
        )
    }
}
