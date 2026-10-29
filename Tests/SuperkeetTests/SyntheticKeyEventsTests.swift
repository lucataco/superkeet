import CoreGraphics
import XCTest
@testable import Superkeet

final class SyntheticKeyEventsTests: XCTestCase {
    func testPostedKeysAreMarkedSoTheHotkeyTapIgnoresThem() throws {
        let escape = try XCTUnwrap(SyntheticKeyEvents.events(virtualKey: 53))
        XCTAssertEqual(escape.count, 2)
        XCTAssertTrue(escape.allSatisfy(SyntheticKeyEvents.isSynthetic))
        XCTAssertEqual(escape.map { $0.type }, [.keyDown, .keyUp])

        let userEscape = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true))
        XCTAssertFalse(SyntheticKeyEvents.isSynthetic(userEscape), "A real Escape still cancels the run.")
    }

    private let modifierMask: CGEventFlags = [
        .maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn, .maskAlphaShift
    ]

    func testShortcutKeyUpCarriesNoModifierSoTheHIDFlagStateIsNotLatched() throws {
        let paste = try XCTUnwrap(SyntheticKeyEvents.events(virtualKey: 9, flags: .maskCommand))
        XCTAssertEqual(paste.map { $0.type }, [.keyDown, .keyUp])
        XCTAssertTrue(paste[0].flags.contains(.maskCommand))
        XCTAssertTrue(paste[1].flags.isDisjoint(with: modifierMask),
                      "A keyUp carrying Command latches it into the HID flag state.")
    }

    func testTypedTextIsKept() throws {
        let typed = try XCTUnwrap(SyntheticKeyEvents.events(virtualKey: 0, text: "héllo 👋"))
        for event in typed {
            var length = 0
            var buffer = [UniChar](repeating: 0, count: 16)
            event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
            XCTAssertEqual(String(utf16CodeUnits: buffer, count: length), "héllo 👋")
            XCTAssertTrue(SyntheticKeyEvents.isSynthetic(event))
        }
    }

    func testPostedShortcutLeavesNoModifierLatchedInHIDState() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SUPERKEET_SYNTHETIC_KEYS_LIVE"] == "1",
                          "Set SUPERKEET_SYNTHETIC_KEYS_LIVE=1 to post real key events.")
        XCTAssertTrue(SyntheticKeyEvents.post(virtualKey: 80, flags: .maskCommand))
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertFalse(CGEventSource.flagsState(.hidSystemState).contains(.maskCommand))
    }
}
