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

    func testShortcutFlagsAndTypedTextAreKept() throws {
        let paste = try XCTUnwrap(SyntheticKeyEvents.events(virtualKey: 9, flags: .maskCommand))
        XCTAssertTrue(paste.allSatisfy { $0.flags.contains(.maskCommand) })

        let typed = try XCTUnwrap(SyntheticKeyEvents.events(virtualKey: 0, text: "héllo 👋"))
        for event in typed {
            var length = 0
            var buffer = [UniChar](repeating: 0, count: 16)
            event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
            XCTAssertEqual(String(utf16CodeUnits: buffer, count: length), "héllo 👋")
            XCTAssertTrue(SyntheticKeyEvents.isSynthetic(event))
        }
    }
}
