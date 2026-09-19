import Foundation
import AppKit
import Combine
import os

private let hotkeyLog = Logger(subsystem: "com.superkeet.app", category: "HotkeyManager")

/// Global shortcut listener.
///
/// The CGEvent tap is a synchronous filter for every keystroke on the system, so it runs on its
/// own thread: a busy main thread (settings UI, readiness probes, SwiftUI layout) must never delay
/// typing in other apps or trip macOS's tap-timeout watchdog. The tap thread reads a lock-protected
/// `HotkeyConfig` snapshot, runs the pure `HotkeyDecider`, returns the consume verdict immediately,
/// and hops only the resulting actions back to the main thread.
final class HotkeyManager: ObservableObject, @unchecked Sendable {
    static let shared = HotkeyManager()

    @Published var isListening: Bool = false
    @Published var accessibilityGranted: Bool = false

    var onToggleHotkeyPressed: (() -> Void)?
    var onPushToTalkStarted: (() -> Void)?
    var onPushToTalkEnded: (() -> Void)?
    var onCommandHotkeyPressed: (() -> Void)?
    var onEscapePressed: (@MainActor () -> Void)?

    private let settings = AppSettings.shared
    private var retryTimer: Timer?
    private var retainedSelf: Unmanaged<HotkeyManager>?
    private var tapThread: EventTapThread?
    private var configObservers: Set<AnyCancellable> = []
    private var hotkeyCaptureCount: Int = 0

    // Shared with the tap thread.
    private let decider = OSAllocatedUnfairLock(initialState: HotkeyDecider())
    private let config = OSAllocatedUnfairLock(initialState: HotkeyConfig.placeholder)
    private let tapPort = NSLock()
    private var eventTapStorage: CFMachPort?
    private let tapHealth = OSAllocatedUnfairLock(initialState: TapHealth())

    private struct TapHealth: Sendable {
        var reEnableCount = 0
        var windowStart = Date.distantPast
    }

    private init() {
        self.accessibilityGranted = checkAccessibilitySilently()
    }

    private var eventTap: CFMachPort? {
        get { tapPort.withLock { eventTapStorage } }
        set { tapPort.withLock { eventTapStorage = newValue } }
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

        installConfigObservers()
        refreshConfigSnapshot()

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
        tapHealth.withLock { $0 = TapHealth() }

        let thread = EventTapThread(tap: tap)
        thread.start()
        thread.waitUntilRunning()
        self.tapThread = thread

        hotkeyLog.info("Event tap listening on its own thread. Toggle=\(self.settings.toggleHotkeyDisplayName), PTT=\(self.settings.pttHotkeyDisplayName)")

        self.isListening = true
    }

    func stopListening() {
        dispatchPrecondition(condition: .onQueue(.main))
        stopRetryTimer()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            tapThread?.stop()
            CFMachPortInvalidate(tap)
            retainedSelf?.release()
            retainedSelf = nil
        }
        tapThread = nil
        eventTap = nil
        self.isListening = false
        decider.withLock { $0.reset() }
    }

    func beginHotkeyCapture() {
        dispatchPrecondition(condition: .onQueue(.main))
        hotkeyCaptureCount += 1
        refreshConfigSnapshot()
        let actions = decider.withLock { $0.releasePushToTalk() }
        MainActor.assumeIsolated { actions.forEach(perform) }
    }

    func endHotkeyCapture() {
        dispatchPrecondition(condition: .onQueue(.main))
        hotkeyCaptureCount = max(0, hotkeyCaptureCount - 1)
        refreshConfigSnapshot()
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

    // MARK: - Config snapshot (main thread → tap thread)

    private func installConfigObservers() {
        guard configObservers.isEmpty else { return }
        // Hotkey assignments and actionsEnabled live in UserDefaults; recording/action state is @Published.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshConfigSnapshot() }
            .store(in: &configObservers)
        settings.$isRecording
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshConfigSnapshot() }
            .store(in: &configObservers)
        settings.$isActionSessionActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshConfigSnapshot() }
            .store(in: &configObservers)
    }

    private func refreshConfigSnapshot() {
        let snapshot = currentConfig()
        config.withLock { $0 = snapshot }
    }

    private func currentConfig() -> HotkeyConfig {
        HotkeyConfig(
            toggleKeyCode: settings.toggleHotkeyKeyCode,
            toggleModifiers: settings.toggleHotkeyModifierFlags,
            pttKeyCode: settings.pttHotkeyKeyCode,
            pttModifiers: settings.pttHotkeyModifierFlags,
            commandKeyCode: settings.commandHotkeyKeyCode,
            commandModifiers: settings.commandHotkeyModifierFlags,
            actionsEnabled: settings.actionsEnabled,
            isRecording: settings.isRecording,
            isActionSessionActive: settings.isActionSessionActive,
            captureActive: hotkeyCaptureCount > 0
        )
    }

    // MARK: - Event handling

    /// Main-thread entry point (tests and direct callers). Reads live settings so state changes
    /// made moments ago are honoured, and performs the resulting actions synchronously.
    @MainActor
    func handleEvent(_ event: HotkeyEvent) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        let snapshot = currentConfig()
        let decision = decider.withLock { $0.decide(event, config: snapshot) }
        decision.actions.forEach(perform)
        return decision.consume
    }

    /// Tap-thread entry point. Must return without blocking; actions are dispatched to main.
    fileprivate nonisolated func handleTapEvent(_ event: HotkeyEvent) -> Bool {
        let snapshot = config.withLock { $0 }
        let decision = decider.withLock { $0.decide(event, config: snapshot) }
        if !decision.actions.isEmpty {
            let actions = decision.actions
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { actions.forEach { self?.perform($0) } }
            }
        }
        return decision.consume
    }

    /// The system disabled the tap (timeout or user input). Release any held key, then re-enable
    /// with a back-off so a wedged tap does not spin.
    fileprivate nonisolated func handleTapDisabled() {
        let released = decider.withLock { $0.releasePushToTalk() }
        if !released.isEmpty {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { released.forEach { self?.perform($0) } }
            }
        }

        let shouldReEnable: Bool = tapHealth.withLock { health in
            let now = Date()
            if now.timeIntervalSince(health.windowStart) > 10 {
                health.reEnableCount = 0
                health.windowStart = now
            }
            health.reEnableCount += 1
            return health.reEnableCount <= 5
        }

        if shouldReEnable {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        } else {
            hotkeyLog.warning("Event tap disabled repeatedly, backing off. Will retry via timer.")
            DispatchQueue.main.async { [weak self] in
                self?.stopListening()
                self?.startRetryTimer()
            }
        }
    }

    @MainActor
    private func perform(_ action: HotkeyAction) {
        switch action {
        case .escape:
            hotkeyLog.info("Escape pressed while active — cancelling")
            onEscapePressed?()
        case .toggle:
            hotkeyLog.info("Toggle hotkey pressed")
            onToggleHotkeyPressed?()
        case .pushToTalkStart:
            hotkeyLog.info("PTT key pressed — starting recording")
            onPushToTalkStarted?()
        case .pushToTalkEnd:
            hotkeyLog.info("PTT key released — stopping recording")
            onPushToTalkEnded?()
        case .command:
            hotkeyLog.info("Command hotkey pressed")
            onCommandHotkeyPressed?()
        }
    }

    static func modifiersMatch(_ eventFlags: CGEventFlags, required: Int) -> Bool {
        HotkeyDecider.modifiersMatch(eventFlags, required: required)
    }
}

extension HotkeyConfig {
    /// Used only until the first snapshot is taken; matches nothing.
    static let placeholder = HotkeyConfig(
        toggleKeyCode: -1, toggleModifiers: 0,
        pttKeyCode: -1, pttModifiers: 0,
        commandKeyCode: -1, commandModifiers: 0,
        actionsEnabled: false, isRecording: false, isActionSessionActive: false, captureActive: false
    )
}

/// Hosts the event tap's run loop so keystroke filtering never waits on the main thread.
private final class EventTapThread: Thread {
    private let source: CFRunLoopSource
    private let running = DispatchSemaphore(value: 0)
    private let loopLock = NSLock()
    private var loop: CFRunLoop?

    init(tap: CFMachPort) {
        self.source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        super.init()
        name = "com.superkeet.hotkey-tap"
        qualityOfService = .userInteractive
    }

    override func main() {
        let current = CFRunLoopGetCurrent()
        loopLock.withLock { loop = current }
        CFRunLoopAddSource(current, source, .commonModes)
        running.signal()
        CFRunLoopRun()
        CFRunLoopRemoveSource(current, source, .commonModes)
    }

    func waitUntilRunning() {
        running.wait()
    }

    func stop() {
        CFRunLoopSourceInvalidate(source)
        if let loop = loopLock.withLock({ loop }) {
            CFRunLoopStop(loop)
        }
    }
}

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        manager.handleTapDisabled()
        return Unmanaged.passUnretained(event)
    }

    let keyboard = HotkeyEvent(type: event.type, keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                               flags: event.flags, isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
    return manager.handleTapEvent(keyboard) ? nil : Unmanaged.passUnretained(event)
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

func hotkeyAssignmentsConflict(
    firstKeyCode: Int,
    firstModifiers: Int,
    secondKeyCode: Int,
    secondModifiers: Int
) -> Bool {
    firstKeyCode == secondKeyCode && firstModifiers == secondModifiers
}
