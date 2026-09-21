import CoreGraphics
import Foundation

/// Everything the hotkey state machine needs to know about the app, captured as a value so the
/// event tap can evaluate keystrokes off the main thread without touching main-actor state.
struct HotkeyConfig: Equatable, Sendable {
    var toggleKeyCode: Int
    var toggleModifiers: Int
    var pttKeyCode: Int
    var pttModifiers: Int
    var commandKeyCode: Int
    var commandModifiers: Int
    var commandPTTKeyCode: Int
    var commandPTTModifiers: Int
    var actionsEnabled: Bool
    var isRecording: Bool
    var isActionSessionActive: Bool
    /// A shortcut recorder is open; every key belongs to it.
    var captureActive: Bool

    static let fnKeyCode = 63
    static let escapeKeyCode = 53
}

/// Something the app should do in response to a keystroke. Performed on the main thread.
enum HotkeyAction: Equatable, Sendable {
    case escape
    case toggle
    case pushToTalkStart
    case pushToTalkEnd
    case command
    case commandPushToTalkStart
    case commandPushToTalkEnd
}

struct HotkeyDecision: Equatable, Sendable {
    /// Whether the keystroke is swallowed so the focused app never sees it.
    var consume: Bool
    var actions: [HotkeyAction]

    static let passThrough = HotkeyDecision(consume: false, actions: [])
    static func consumed(_ actions: HotkeyAction...) -> HotkeyDecision {
        HotkeyDecision(consume: true, actions: actions)
    }
}

/// Pure hotkey state machine. Owns the held-key state (push-to-talk, fn) so it can be driven from
/// the event tap thread; the consume/pass-through verdict must be returned synchronously to the
/// system, so nothing in here may block or hop threads.
struct HotkeyDecider: Sendable {
    private(set) var pttKeyDown = false
    private(set) var commandPTTKeyDown = false
    private(set) var fnKeyDown = false

    /// Releases a held push-to-talk key, e.g. when a shortcut recorder opens or the tap is disabled
    /// mid-press. Returns the actions needed to stop the recordings those keys started.
    mutating func releasePushToTalk() -> [HotkeyAction] {
        fnKeyDown = false
        var actions: [HotkeyAction] = []
        if pttKeyDown {
            pttKeyDown = false
            actions.append(.pushToTalkEnd)
        }
        if commandPTTKeyDown {
            commandPTTKeyDown = false
            actions.append(.commandPushToTalkEnd)
        }
        return actions
    }

    mutating func reset() {
        pttKeyDown = false
        commandPTTKeyDown = false
        fnKeyDown = false
    }

    mutating func decide(_ event: HotkeyEvent, config: HotkeyConfig) -> HotkeyDecision {
        if config.captureActive { return .passThrough }

        let keyCode = Int(event.keyCode)
        let flags = event.flags
        let isKeyDown = event.type == .keyDown

        let escapeModifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]
        switch EscapeHotkeyPolicy.action(
            isKeyDown: isKeyDown,
            matchesEscape: keyCode == HotkeyConfig.escapeKeyCode && flags.isDisjoint(with: escapeModifiers),
            isRepeat: event.isRepeat,
            isRecording: config.isRecording,
            actionSessionActive: config.isActionSessionActive
        ) {
        case .ignore: break
        case .cancelAndPassThrough: return HotkeyDecision(consume: false, actions: [.escape])
        case .cancelAndConsume: return .consumed(.escape)
        }

        if event.type == .flagsChanged && keyCode == HotkeyConfig.fnKeyCode {
            return decideFnKey(pressed: flags.contains(.maskSecondaryFn), config: config)
        }

        if config.actionsEnabled, keyCode == config.commandKeyCode, config.commandKeyCode != HotkeyConfig.fnKeyCode {
            switch ToggleHotkeyPolicy.action(
                isKeyDown: isKeyDown,
                matchesShortcut: Self.modifiersMatch(flags, required: config.commandModifiers),
                isRepeat: event.isRepeat
            ) {
            case .toggle: return .consumed(.command)
            case .consumeRepeat: return .consumed()
            case .ignore: break
            }
        }

        // Hold-to-talk for Actions Mode. A release always ends a recording the key started, even
        // if Actions Mode was switched off mid-press.
        if keyCode == config.commandPTTKeyCode, config.commandPTTKeyCode != HotkeyConfig.fnKeyCode,
           config.actionsEnabled || commandPTTKeyDown {
            switch PTTHotkeyPolicy.keyAction(
                isKeyDown: isKeyDown,
                pttAlreadyDown: commandPTTKeyDown,
                modifiersMatch: config.actionsEnabled && Self.modifiersMatch(flags, required: config.commandPTTModifiers)
            ) {
            case .ignore: break
            case .start:
                commandPTTKeyDown = true
                return .consumed(.commandPushToTalkStart)
            case .consumeRepeat: return .consumed()
            case .stop:
                commandPTTKeyDown = false
                return .consumed(.commandPushToTalkEnd)
            }
        }

        switch ToggleHotkeyPolicy.action(
            isKeyDown: isKeyDown,
            matchesShortcut: keyCode == config.toggleKeyCode && Self.modifiersMatch(flags, required: config.toggleModifiers),
            isRepeat: event.isRepeat
        ) {
        case .toggle: return .consumed(.toggle)
        case .consumeRepeat: return .consumed()
        case .ignore: break
        }

        if keyCode == config.pttKeyCode, config.pttKeyCode != HotkeyConfig.fnKeyCode {
            switch PTTHotkeyPolicy.keyAction(
                isKeyDown: isKeyDown,
                pttAlreadyDown: pttKeyDown,
                modifiersMatch: Self.modifiersMatch(flags, required: config.pttModifiers)
            ) {
            case .ignore: break
            case .start:
                pttKeyDown = true
                return .consumed(.pushToTalkStart)
            case .consumeRepeat: return .consumed()
            case .stop:
                pttKeyDown = false
                return .consumed(.pushToTalkEnd)
            }
        }

        return .passThrough
    }

    private mutating func decideFnKey(pressed fnPressed: Bool, config: HotkeyConfig) -> HotkeyDecision {
        if config.toggleKeyCode == HotkeyConfig.fnKeyCode && config.toggleModifiers == 0 {
            if fnPressed && !fnKeyDown {
                fnKeyDown = true
                return .consumed(.toggle)
            } else if !fnPressed {
                fnKeyDown = false
            }
            return .passThrough
        }

        if config.pttKeyCode == HotkeyConfig.fnKeyCode && config.pttModifiers == 0 {
            if fnPressed && !fnKeyDown {
                fnKeyDown = true
                pttKeyDown = true
                return .consumed(.pushToTalkStart)
            } else if !fnPressed && fnKeyDown {
                fnKeyDown = false
                pttKeyDown = false
                return .consumed(.pushToTalkEnd)
            }
            return .passThrough
        }

        if config.commandPTTKeyCode == HotkeyConfig.fnKeyCode && config.commandPTTModifiers == 0 && (config.actionsEnabled || commandPTTKeyDown) {
            if fnPressed && !fnKeyDown && config.actionsEnabled {
                fnKeyDown = true
                commandPTTKeyDown = true
                return .consumed(.commandPushToTalkStart)
            } else if !fnPressed && commandPTTKeyDown {
                fnKeyDown = false
                commandPTTKeyDown = false
                return .consumed(.commandPushToTalkEnd)
            }
            return .passThrough
        }

        return .passThrough
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
