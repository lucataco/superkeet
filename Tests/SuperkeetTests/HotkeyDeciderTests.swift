import CoreGraphics
import XCTest
@testable import Superkeet

final class HotkeyDeciderTests: XCTestCase {
    private let optionSpace = 524_288
    private let optionShiftSpace = 655_360

    private func config(
        toggle: (Int, Int) = (49, 524_288),
        ptt: (Int, Int) = (63, 0),
        command: (Int, Int) = (49, 655_360),
        actionsEnabled: Bool = false,
        isRecording: Bool = false,
        actionActive: Bool = false,
        capture: Bool = false
    ) -> HotkeyConfig {
        HotkeyConfig(
            toggleKeyCode: toggle.0, toggleModifiers: toggle.1,
            pttKeyCode: ptt.0, pttModifiers: ptt.1,
            commandKeyCode: command.0, commandModifiers: command.1,
            actionsEnabled: actionsEnabled,
            isRecording: isRecording,
            isActionSessionActive: actionActive,
            captureActive: capture
        )
    }

    private func key(_ code: Int64, _ flags: CGEventFlags = [], down: Bool = true, repeat isRepeat: Bool = false) -> HotkeyEvent {
        HotkeyEvent(type: down ? .keyDown : .keyUp, keyCode: code, flags: flags, isRepeat: isRepeat)
    }

    private func fn(pressed: Bool) -> HotkeyEvent {
        HotkeyEvent(type: .flagsChanged, keyCode: 63, flags: pressed ? .maskSecondaryFn : [], isRepeat: false)
    }

    func testToggleShortcutIsConsumedAndFiresOncePerPress() {
        var decider = HotkeyDecider()
        XCTAssertEqual(decider.decide(key(49, .maskAlternate), config: config()), .consumed(.toggle))
        XCTAssertEqual(decider.decide(key(49, .maskAlternate, repeat: true), config: config()), .consumed())
        XCTAssertEqual(decider.decide(key(49, .maskAlternate, down: false), config: config()), .passThrough)
        XCTAssertEqual(decider.decide(key(49), config: config()), .passThrough, "plain Space is not the shortcut")
    }

    func testCommandShortcutOnlyWorksWhenActionsAreEnabled() {
        var decider = HotkeyDecider()
        let press = key(49, [.maskAlternate, .maskShift])
        XCTAssertEqual(decider.decide(press, config: config(actionsEnabled: false)), .passThrough)
        XCTAssertEqual(decider.decide(press, config: config(actionsEnabled: true)), .consumed(.command))
    }

    func testFnPushToTalkTracksPressAndRelease() {
        var decider = HotkeyDecider()
        XCTAssertEqual(decider.decide(fn(pressed: true), config: config()), .consumed(.pushToTalkStart))
        XCTAssertTrue(decider.pttKeyDown)
        XCTAssertEqual(decider.decide(fn(pressed: true), config: config()), .passThrough, "held fn does not re-fire")
        XCTAssertEqual(decider.decide(fn(pressed: false), config: config()), .consumed(.pushToTalkEnd))
        XCTAssertFalse(decider.pttKeyDown)
        XCTAssertEqual(decider.decide(fn(pressed: false), config: config()), .passThrough)
    }

    func testRegularKeyPushToTalkTracksPressAndRelease() {
        var decider = HotkeyDecider()
        let cfg = config(ptt: (3, 0)) // F
        XCTAssertEqual(decider.decide(key(3), config: cfg), .consumed(.pushToTalkStart))
        XCTAssertEqual(decider.decide(key(3, repeat: true), config: cfg), .consumed())
        XCTAssertEqual(decider.decide(key(3, down: false), config: cfg), .consumed(.pushToTalkEnd))
        XCTAssertEqual(decider.decide(key(3, .maskCommand), config: cfg), .passThrough, "⌘F is not bare F")
    }

    func testReleasingPushToTalkExternallyReportsTheEnd() {
        var decider = HotkeyDecider()
        XCTAssertEqual(decider.releasePushToTalk(), [], "nothing held")
        _ = decider.decide(fn(pressed: true), config: config())
        XCTAssertEqual(decider.releasePushToTalk(), [.pushToTalkEnd])
        XCTAssertFalse(decider.pttKeyDown)
        XCTAssertFalse(decider.fnKeyDown)
    }

    func testShortcutRecorderCaptureSwallowsNothingAndFiresNothing() {
        var decider = HotkeyDecider()
        let cfg = config(actionsEnabled: true, isRecording: true, capture: true)
        XCTAssertEqual(decider.decide(key(49, .maskAlternate), config: cfg), .passThrough)
        XCTAssertEqual(decider.decide(key(53), config: cfg), .passThrough)
        XCTAssertEqual(decider.decide(fn(pressed: true), config: cfg), .passThrough)
    }

    func testEscapeIsConsumedWhileRecordingButPassedThroughDuringAnAction() {
        var decider = HotkeyDecider()
        XCTAssertEqual(decider.decide(key(53), config: config()), .passThrough, "idle Escape is untouched")
        XCTAssertEqual(decider.decide(key(53), config: config(isRecording: true)), .consumed(.escape))
        XCTAssertEqual(
            decider.decide(key(53), config: config(isRecording: true, actionActive: true)),
            HotkeyDecision(consume: false, actions: [.escape])
        )
        XCTAssertEqual(decider.decide(key(53, .maskCommand), config: config(isRecording: true)), .passThrough)
        XCTAssertEqual(decider.decide(key(53, repeat: true), config: config(isRecording: true)), .passThrough)
    }

    func testFnAsToggleFiresOnPressOnly() {
        var decider = HotkeyDecider()
        let cfg = config(toggle: (63, 0), ptt: (3, 0))
        XCTAssertEqual(decider.decide(fn(pressed: true), config: cfg), .consumed(.toggle))
        XCTAssertEqual(decider.decide(fn(pressed: true), config: cfg), .passThrough)
        XCTAssertEqual(decider.decide(fn(pressed: false), config: cfg), .passThrough)
        XCTAssertEqual(decider.decide(fn(pressed: true), config: cfg), .consumed(.toggle))
    }

    func testDeciderStateSurvivesConfigChangesBetweenEvents() {
        // Settings can be edited mid-press; the release must still end the recording.
        var decider = HotkeyDecider()
        XCTAssertEqual(decider.decide(fn(pressed: true), config: config()), .consumed(.pushToTalkStart))
        let rebound = config(isRecording: true)
        XCTAssertEqual(decider.decide(fn(pressed: false), config: rebound), .consumed(.pushToTalkEnd))
    }
}
