import Foundation
import Carbon
import AppKit
import os.log

private let hotkeyLog = Logger(subsystem: "com.superkeet.app", category: "HotkeyManager")

/// Global hotkey manager using CGEvent tap for monitoring keyboard events system-wide.
/// Supports two independent hotkeys:
///   1. Toggle Recording — press to start, press again to stop
///   2. Push to Talk — hold to record, release to stop
/// Requires Accessibility permission.
final class HotkeyManager: ObservableObject {
    static let shared = HotkeyManager()

    @Published var isListening: Bool = false
    @Published var accessibilityGranted: Bool = false

    // MARK: - Callbacks

    /// Toggle hotkey fired (press to start/stop)
    var onToggleHotkeyPressed: (() -> Void)?
    /// Push-to-talk key pressed down (start recording)
    var onPushToTalkStarted: (() -> Void)?
    /// Push-to-talk key released (stop recording)
    var onPushToTalkEnded: (() -> Void)?
    /// Escape key pressed while recording
    var onEscapePressed: (() -> Void)?

    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let settings = AppSettings.shared
    private var retryTimer: Timer?
    /// Stores the retained self reference passed to the event tap's userInfo.
    /// Must be released exactly once in stopListening() to balance passRetained().
    private var retainedSelf: Unmanaged<HotkeyManager>?

    /// Track whether the PTT key is currently held to avoid repeat keyDown events
    fileprivate var pttKeyDown: Bool = false
    /// Track previous fn key state for edge detection (fn only fires flagsChanged)
    fileprivate var fnKeyDown: Bool = false
    /// Track rapid tap re-enables to detect a tight re-enable loop
    fileprivate var tapReEnableCount: Int = 0
    fileprivate var tapReEnableWindowStart: Date = .distantPast

    private init() {
        // Only check silently at init – don't show the macOS system dialog.
        // The prompting dialog will appear during onboarding (Permissions step)
        // or after onboarding completes via completeOnboarding().
        self.accessibilityGranted = checkAccessibilitySilently()
    }

    // MARK: - Accessibility

    func checkAccessibilitySilently() -> Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    func checkAccessibility() -> Bool {
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        )
        self.accessibilityGranted = trusted
        return trusted
    }

    // MARK: - Start / Stop

    func startListening() {
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

        // Listen for keyDown, keyUp, and flagsChanged (for modifier-only keys like fn)
        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: hotkeyCallback,
            userInfo: { [self] in
                let retained = Unmanaged.passRetained(self)
                self.retainedSelf = retained
                return retained.toOpaque()
            }()
        )

        guard let tap = tap else {
            hotkeyLog.error("Failed to create event tap. CGEvent.tapCreate returned nil.")
            return
        }

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
        stopRetryTimer()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
            // Balance the passRetained(self) from startListening()
            retainedSelf?.release()
            retainedSelf = nil
        }
        eventTap = nil
        runLoopSource = nil
        self.isListening = false
    }

    // MARK: - Retry

    /// Start a periodic retry that attempts to create the event tap once
    /// Accessibility permission is granted. Stops automatically on success.
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

    // MARK: - Event Handling

    fileprivate func handleEvent(_ event: CGEvent) -> Bool {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let eventType = event.type

        // --- Escape key (keyCode 53) cancels recording when active ---
        if eventType == .keyDown && keyCode == 53 && settings.isRecording {
            hotkeyLog.info("Escape pressed while recording — cancelling")
            onEscapePressed?()
            return true
        }

        // --- Handle fn key separately (only fires flagsChanged, not keyDown/keyUp) ---
        if eventType == .flagsChanged && keyCode == 63 {
            let fnPressed = flags.contains(.maskSecondaryFn)

            // Check if fn is the Toggle Recording hotkey
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

            // Check if fn is the Push to Talk hotkey
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

        // --- Toggle Recording hotkey (keyDown only) ---
        if eventType == .keyDown && Int(keyCode) == settings.toggleHotkeyKeyCode {
            if matchesModifiers(flags, required: settings.toggleHotkeyModifierFlags) {
                hotkeyLog.info("Toggle hotkey pressed (keyCode=\(keyCode))")
                onToggleHotkeyPressed?()
                return true
            }
        }

        // --- Push to Talk hotkey (keyDown = start, keyUp = stop) ---
        if Int(keyCode) == settings.pttHotkeyKeyCode && settings.pttHotkeyKeyCode != 63 {
            if eventType == .keyDown && !pttKeyDown {
                if matchesModifiers(flags, required: settings.pttHotkeyModifierFlags) {
                    pttKeyDown = true
                    hotkeyLog.info("PTT key pressed (keyCode=\(keyCode)) — starting recording")
                    onPushToTalkStarted?()
                    return true
                }
            } else if eventType == .keyUp && pttKeyDown {
                pttKeyDown = false
                hotkeyLog.info("PTT key released (keyCode=\(keyCode)) — stopping recording")
                onPushToTalkEnded?()
                return true
            }
        }

        return false
    }

    /// Check whether the event's modifier flags match the required flags.
    /// Only checks the significant modifier bits (Cmd, Option, Control, Shift).
    func matchesModifiers(_ eventFlags: CGEventFlags, required: Int) -> Bool {
        Self.modifiersMatch(eventFlags, required: required)
    }

    /// Pure logic for modifier matching, exposed for testability.
    static func modifiersMatch(_ eventFlags: CGEventFlags, required: Int) -> Bool {
        let significant: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        if required == 0 {
            // No modifiers required — match if no significant modifiers are pressed
            return eventFlags.intersection(significant).isEmpty
        }
        let requiredFlags = CGEventFlags(rawValue: UInt64(required))
        return eventFlags.intersection(significant) == requiredFlags.intersection(significant)
    }
}

// MARK: - Key Code Display Names

/// Converts a key code and modifier flags into a human-readable string (e.g., "⌥ Space", "⌘⇧R")
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

/// Maps common key codes to display names
func keyCodeName(_ keyCode: Int) -> String {
    switch keyCode {
    // Letters (QWERTY layout)
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
    // Special keys
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

// MARK: - Global C callback for CGEvent tap

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // Handle tap being disabled by the system
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let userInfo = userInfo {
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
            // Reset PTT state — a keyUp may have been missed while the tap was disabled
            if manager.pttKeyDown {
                manager.pttKeyDown = false
                manager.fnKeyDown = false
                manager.onPushToTalkEnded?()
            }
            // Backoff: if re-enabled too many times in a short window, stop trying
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
                manager.stopListening()
                manager.startRetryTimer()
            }
        }
        return Unmanaged.passUnretained(event)
    }

    guard let userInfo = userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
    let handled = manager.handleEvent(event)
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
