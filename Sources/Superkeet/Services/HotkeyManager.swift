import Foundation
import AppKit
import os.log

private let hotkeyLog = Logger(subsystem: "com.superkeet.app", category: "HotkeyManager")

final class HotkeyManager: ObservableObject, @unchecked Sendable {
    static let shared = HotkeyManager()

    @Published var isListening: Bool = false
    @Published var accessibilityGranted: Bool = false

    var onToggleHotkeyPressed: (() -> Void)?
    var onPushToTalkStarted: (() -> Void)?
    var onPushToTalkEnded: (() -> Void)?
    var onCommandHotkeyPressed: (() -> Void)?
    var onEscapePressed: (@MainActor () -> Void)?

    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let settings = AppSettings.shared
    private var retryTimer: Timer?
    private var retainedSelf: Unmanaged<HotkeyManager>?

    fileprivate var pttKeyDown: Bool = false
    fileprivate var fnKeyDown: Bool = false
    fileprivate var tapReEnableCount: Int = 0
    fileprivate var tapReEnableWindowStart: Date = .distantPast
    private var hotkeyCaptureCount: Int = 0

    private init() {
        self.accessibilityGranted = checkAccessibilitySilently()
    }

    func checkAccessibilitySilently() -> Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    func checkAccessibility() -> Bool {
        let trusted = AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        )
        self.accessibilityGranted = trusted
        return trusted
    }

    func startListening() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard eventTap == nil else {
            hotkeyLog.info("Already listening, skipping startListening()")
            return
        }

        let accessible = checkAccessibilitySilently()
        hotkeyLog.info("Accessibility check: \(accessible ? "granted" : "NOT granted")")
        guard accessible else {
            hotkeyLog.warning("Cannot create event tap without Accessibility permission")
            return
        }

        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let retained = Unmanaged.passRetained(self)
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: hotkeyCallback,
            userInfo: retained.toOpaque()
        )

        guard let tap = tap else {
            retained.release()
            hotkeyLog.error("Failed to create event tap. CGEvent.tapCreate returned nil.")
            return
        }

        self.retainedSelf = retained
        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tapReEnableCount = 0
        self.tapReEnableWindowStart = .distantPast

        hotkeyLog.info("Event tap created and listening. Toggle=\(self.settings.toggleHotkeyDisplayName), PTT=\(self.settings.pttHotkeyDisplayName)")

        self.isListening = true
    }

    func stopListening() {
        dispatchPrecondition(condition: .onQueue(.main))
        stopRetryTimer()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
            retainedSelf?.release()
            retainedSelf = nil
        }
        eventTap = nil
        runLoopSource = nil
        self.isListening = false
        pttKeyDown = false
        fnKeyDown = false
    }

    func beginHotkeyCapture() {
        dispatchPrecondition(condition: .onQueue(.main))
        hotkeyCaptureCount += 1
        if pttKeyDown {
            pttKeyDown = false
            fnKeyDown = false
            onPushToTalkEnded?()
        }
    }

    func endHotkeyCapture() {
        dispatchPrecondition(condition: .onQueue(.main))
        hotkeyCaptureCount = max(0, hotkeyCaptureCount - 1)
    }

    func startRetryTimer() {
        guard retryTimer == nil else { return }
        hotkeyLog.info("Starting accessibility retry timer (every 3s)")
        retryTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.isListening {
                self.stopRetryTimer()
                return
            }
            let trusted = AXIsProcessTrusted()
            if trusted {
                hotkeyLog.info("Accessibility now granted — retrying event tap creation")
                self.accessibilityGranted = true
                self.startListening()
                if self.isListening {
                    self.stopRetryTimer()
                }
            }
        }
    }

    private func stopRetryTimer() {
        retryTimer?.invalidate()
        retryTimer = nil
    }

    @MainActor
    func handleEvent(_ event: HotkeyEvent) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        if hotkeyCaptureCount > 0 {
            return false
        }

        let keyCode = event.keyCode
        let flags = event.flags
        let eventType = event.type

        let escapeModifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]
        switch EscapeHotkeyPolicy.action(
            isKeyDown: eventType == .keyDown,
            matchesEscape: keyCode == 53 && flags.isDisjoint(with: escapeModifiers),
            isRepeat: event.isRepeat,
            isRecording: settings.isRecording, actionSessionActive: settings.isActionSessionActive
        ) {
        case .ignore: break
        case .cancelAndPassThrough:
            hotkeyLog.info("Escape pressed during an action — cancelling and passing through")
            onEscapePressed?()
            return false
        case .cancelAndConsume:
            hotkeyLog.info("Escape pressed while active — cancelling")
            onEscapePressed?()
            return true
        }

        if eventType == .flagsChanged && keyCode == 63 {
            let fnPressed = flags.contains(.maskSecondaryFn)

            if settings.toggleHotkeyKeyCode == 63 && settings.toggleHotkeyModifierFlags == 0 {
                if fnPressed && !fnKeyDown {
                    fnKeyDown = true
                    hotkeyLog.info("fn toggle hotkey pressed")
                    onToggleHotkeyPressed?()
                    return true
                } else if !fnPressed {
                    fnKeyDown = false
                }
                return false
            }

            if settings.pttHotkeyKeyCode == 63 && settings.pttHotkeyModifierFlags == 0 {
                if fnPressed && !fnKeyDown {
                    fnKeyDown = true
                    pttKeyDown = true
                    hotkeyLog.info("fn PTT key pressed — starting recording")
                    onPushToTalkStarted?()
                    return true
                } else if !fnPressed && fnKeyDown {
                    fnKeyDown = false
                    pttKeyDown = false
                    hotkeyLog.info("fn PTT key released — stopping recording")
                    onPushToTalkEnded?()
                    return true
                }
                return false
            }

            return false
        }

        if settings.actionsEnabled, Int(keyCode) == settings.commandHotkeyKeyCode && settings.commandHotkeyKeyCode != 63 {
            switch ToggleHotkeyPolicy.action(
                isKeyDown: eventType == .keyDown,
                matchesShortcut: Self.modifiersMatch(flags, required: settings.commandHotkeyModifierFlags),
                isRepeat: event.isRepeat
            ) {
            case .toggle:
                hotkeyLog.info("Command hotkey pressed (keyCode=\(keyCode))")
                onCommandHotkeyPressed?()
                return true
            case .consumeRepeat:
                return true
            case .ignore:
                break
            }
        }

        switch ToggleHotkeyPolicy.action(
            isKeyDown: eventType == .keyDown,
            matchesShortcut: Int(keyCode) == settings.toggleHotkeyKeyCode && Self.modifiersMatch(flags, required: settings.toggleHotkeyModifierFlags),
            isRepeat: event.isRepeat
        ) {
        case .toggle:
            hotkeyLog.info("Toggle hotkey pressed (keyCode=\(keyCode))")
            onToggleHotkeyPressed?()
            return true
        case .consumeRepeat:
            return true
        case .ignore:
            break
        }

        if Int(keyCode) == settings.pttHotkeyKeyCode && settings.pttHotkeyKeyCode != 63 {
            let modifiersMatch = Self.modifiersMatch(flags, required: settings.pttHotkeyModifierFlags)
            switch PTTHotkeyPolicy.keyAction(
                isKeyDown: eventType == .keyDown,
                pttAlreadyDown: pttKeyDown,
                modifiersMatch: modifiersMatch
            ) {
            case .ignore:
                break
            case .start:
                pttKeyDown = true
                hotkeyLog.info("PTT key pressed (keyCode=\(keyCode)) — starting recording")
                onPushToTalkStarted?()
                return true
            case .consumeRepeat:
                return true
            case .stop:
                pttKeyDown = false
                hotkeyLog.info("PTT key released (keyCode=\(keyCode)) — stopping recording")
                onPushToTalkEnded?()
                return true
            }
        }

        return false
    }

    static func modifiersMatch(_ eventFlags: CGEventFlags, required: Int) -> Bool {
        let significant: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        if required == 0 {
            return eventFlags.isDisjoint(with: significant)
        }
        let requiredFlags = CGEventFlags(rawValue: UInt64(required))
        return eventFlags.intersection(significant) == requiredFlags.intersection(significant)
    }
}

func displayNameForHotkey(keyCode: Int, modifierFlags: Int) -> String {
    var parts: [String] = []

    let flags = CGEventFlags(rawValue: UInt64(modifierFlags))
    if flags.contains(.maskControl) { parts.append("⌃") }
    if flags.contains(.maskAlternate) { parts.append("⌥") }
    if flags.contains(.maskShift) { parts.append("⇧") }
    if flags.contains(.maskCommand) { parts.append("⌘") }

    let keyName = keyCodeName(keyCode)
    parts.append(keyName)

    return parts.joined(separator: " ")
}

func keyCodeName(_ keyCode: Int) -> String {
    switch keyCode {
    case 0: return "A"
    case 1: return "S"
    case 2: return "D"
    case 3: return "F"
    case 4: return "H"
    case 5: return "G"
    case 6: return "Z"
    case 7: return "X"
    case 8: return "C"
    case 9: return "V"
    case 11: return "B"
    case 12: return "Q"
    case 13: return "W"
    case 14: return "E"
    case 15: return "R"
    case 16: return "Y"
    case 17: return "T"
    case 18: return "1"
    case 19: return "2"
    case 20: return "3"
    case 21: return "4"
    case 22: return "6"
    case 23: return "5"
    case 24: return "="
    case 25: return "9"
    case 26: return "7"
    case 27: return "-"
    case 28: return "8"
    case 29: return "0"
    case 30: return "]"
    case 31: return "O"
    case 32: return "U"
    case 33: return "["
    case 34: return "I"
    case 35: return "P"
    case 37: return "L"
    case 38: return "J"
    case 39: return "'"
    case 40: return "K"
    case 41: return ";"
    case 42: return "\\"
    case 43: return ","
    case 44: return "/"
    case 45: return "N"
    case 46: return "M"
    case 47: return "."
    case 36: return "Return"
    case 48: return "Tab"
    case 49: return "Space"
    case 51: return "Delete"
    case 53: return "Escape"
    case 63: return "fn"
    case 76: return "Enter"
    case 96: return "F5"
    case 97: return "F6"
    case 98: return "F7"
    case 99: return "F3"
    case 100: return "F8"
    case 101: return "F9"
    case 103: return "F11"
    case 105: return "F13"
    case 107: return "F14"
    case 109: return "F10"
    case 111: return "F12"
    case 113: return "F15"
    case 118: return "F4"
    case 119: return "End"
    case 120: return "F2"
    case 121: return "PageDown"
    case 122: return "F1"
    case 123: return "Left"
    case 124: return "Right"
    case 125: return "Down"
    case 126: return "Up"
    default: return "Key\(keyCode)"
    }
}

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let userInfo = userInfo {
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
            if manager.pttKeyDown {
                manager.pttKeyDown = false
                manager.fnKeyDown = false
                manager.onPushToTalkEnded?()
            }
            let now = Date()
            if now.timeIntervalSince(manager.tapReEnableWindowStart) > 10 {
                manager.tapReEnableCount = 0
                manager.tapReEnableWindowStart = now
            }
            manager.tapReEnableCount += 1
            if manager.tapReEnableCount <= 5 {
                if let tap = manager.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            } else {
                hotkeyLog.warning("Event tap disabled repeatedly (\(manager.tapReEnableCount) times in 10s), backing off. Will retry via timer.")
                DispatchQueue.main.async {
                    manager.stopListening()
                    manager.startRetryTimer()
                }
            }
        }
        return Unmanaged.passUnretained(event)
    }

    guard let userInfo = userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
    let keyboard = HotkeyEvent(type: event.type, keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                               flags: event.flags, isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
    // startListening installs this tap on the main run loop.
    let handled = MainActor.assumeIsolated { manager.handleEvent(keyboard) }
    if handled {
        return nil
    }

    return Unmanaged.passUnretained(event)
}

func hotkeyAssignmentsConflict(
    firstKeyCode: Int,
    firstModifiers: Int,
    secondKeyCode: Int,
    secondModifiers: Int
) -> Bool {
    firstKeyCode == secondKeyCode && firstModifiers == secondModifiers
}
