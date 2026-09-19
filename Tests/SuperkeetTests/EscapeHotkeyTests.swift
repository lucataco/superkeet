import XCTest
import CoreGraphics
@testable import Superkeet

@MainActor
final class EscapeHotkeyTests: XCTestCase {
    private func withManager(_ body: (HotkeyManager, AppSettings) -> Void) {
        let manager = HotkeyManager.shared
        let settings = AppSettings.shared
        let callback = manager.onEscapePressed
        let recording = settings.isRecording
        let action = settings.isActionSessionActive
        let toggleCode = settings.toggleHotkeyKeyCode
        let pttCode = settings.pttHotkeyKeyCode
        let commandCode = settings.commandHotkeyKeyCode
        settings.toggleHotkeyKeyCode = 49
        settings.pttHotkeyKeyCode = 63
        settings.commandHotkeyKeyCode = 50
        defer {
            manager.onEscapePressed = callback
            settings.isRecording = recording
            settings.isActionSessionActive = action
            settings.toggleHotkeyKeyCode = toggleCode
            settings.pttHotkeyKeyCode = pttCode
            settings.commandHotkeyKeyCode = commandCode
        }
        body(manager, settings)
    }

    func testActionEscapeCancelsSynchronouslyAndPassesToFocusedApp() {
        withManager { manager, settings in
            settings.isRecording = false
            settings.isActionSessionActive = true
            var calls = 0
            manager.onEscapePressed = { calls += 1; settings.isActionSessionActive = false }
            let consumed = manager.handleEvent(HotkeyEvent(type: .keyDown, keyCode: 53, flags: [], isRepeat: false))
            XCTAssertFalse(consumed)
            XCTAssertEqual(calls, 1)
            XCTAssertFalse(settings.isActionSessionActive)
            XCTAssertFalse(manager.handleEvent(HotkeyEvent(type: .keyUp, keyCode: 53, flags: [], isRepeat: false)))
            XCTAssertEqual(calls, 1)
        }
    }

    func testModifiersAndAutorepeatDoNotCancelReplacementSession() {
        withManager { manager, settings in
            settings.isRecording = false
            settings.isActionSessionActive = true
            var calls = 0
            manager.onEscapePressed = { calls += 1 }
            let combinations: [CGEventFlags] = [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn, [.maskCommand, .maskAlternate]]
            for flags in combinations {
                XCTAssertFalse(manager.handleEvent(HotkeyEvent(type: .keyDown, keyCode: 53, flags: flags, isRepeat: false)))
            }
            XCTAssertFalse(manager.handleEvent(HotkeyEvent(type: .keyDown, keyCode: 53, flags: [], isRepeat: true)))
            XCTAssertEqual(calls, 0)
            XCTAssertTrue(settings.isActionSessionActive)
        }
    }

    func testRecordingOnlyEscapeKeepsItsConsumeBehaviorButActionTakesPassThroughPriority() {
        withManager { manager, settings in
            settings.isRecording = true
            settings.isActionSessionActive = false
            var calls = 0
            manager.onEscapePressed = { calls += 1 }
            let escape = HotkeyEvent(type: .keyDown, keyCode: 53, flags: .maskAlphaShift, isRepeat: false)
            XCTAssertTrue(manager.handleEvent(escape))
            settings.isActionSessionActive = true
            XCTAssertFalse(manager.handleEvent(escape))
            XCTAssertEqual(calls, 2)
        }
    }

    func testIdleAndShortcutCaptureEscapeAreUntouched() {
        withManager { manager, settings in
            settings.isRecording = false
            settings.isActionSessionActive = false
            var calls = 0
            manager.onEscapePressed = { calls += 1 }
            let escape = HotkeyEvent(type: .keyDown, keyCode: 53, flags: [], isRepeat: false)
            XCTAssertFalse(manager.handleEvent(escape))
            settings.isActionSessionActive = true
            manager.beginHotkeyCapture()
            defer { manager.endHotkeyCapture() }
            XCTAssertFalse(manager.handleEvent(escape))
            XCTAssertEqual(calls, 0)
        }
    }
}
