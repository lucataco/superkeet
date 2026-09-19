import Carbon.HIToolbox
import CoreGraphics
import Foundation

struct KeyboardShortcut: Equatable, Hashable, Sendable {
    enum Modifier: String, CaseIterable, Sendable {
        case command, shift, option, control

        var flag: CGEventFlags {
            switch self {
            case .command: return .maskCommand
            case .shift: return .maskShift
            case .option: return .maskAlternate
            case .control: return .maskControl
            }
        }

        var symbol: String {
            switch self {
            case .control: return "⌃"
            case .option: return "⌥"
            case .shift: return "⇧"
            case .command: return "⌘"
            }
        }

        static let displayOrder: [Modifier] = [.control, .option, .shift, .command]

        init?(spoken: String) {
            switch spoken.lowercased().trimmingCharacters(in: .whitespaces) {
            case "cmd", "command", "⌘": self = .command
            case "shift", "⇧": self = .shift
            case "option", "opt", "alt", "⌥": self = .option
            case "ctrl", "control", "⌃": self = .control
            default: return nil
            }
        }
    }

    let modifiers: Set<Modifier>
    let key: String
    let keyCode: CGKeyCode

    var flags: CGEventFlags {
        modifiers.reduce(CGEventFlags()) { $0.union($1.flag) }
    }

    var displayName: String {
        let mods = Modifier.displayOrder.filter(modifiers.contains).map(\.symbol).joined()
        return mods + Self.displayNames[key, default: key.uppercased()]
    }

    var keys: [String] {
        Modifier.displayOrder.filter(modifiers.contains).map { $0 == .command ? "cmd" : $0.rawValue } + [key]
    }

    init?(modifiers: Set<Modifier>, key: String) {
        let canonical = Self.canonicalKeyName(key)
        guard let code = Self.keyCodes[canonical] else { return nil }
        if modifiers.isEmpty, !Self.standaloneKeys.contains(canonical) { return nil }
        self.modifiers = modifiers
        self.key = canonical
        self.keyCode = code
    }

    init?(keys: [String]) {
        var modifiers = Set<Modifier>()
        var key: String?
        for token in keys {
            if let modifier = Modifier(spoken: token) {
                modifiers.insert(modifier)
            } else if key == nil {
                key = token
            } else {
                return nil
            }
        }
        guard let key else { return nil }
        self.init(modifiers: modifiers, key: key)
    }

    static func canonicalKeyName(_ raw: String) -> String {
        let lowered = raw.lowercased().trimmingCharacters(in: .whitespaces)
        return aliases[lowered] ?? lowered
    }

    private static let aliases: [String: String] = [
        "enter": "return", "esc": "escape", "backspace": "delete", "del": "forwarddelete",
        "spacebar": "space", "arrowup": "up", "arrowdown": "down", "arrowleft": "left", "arrowright": "right",
        "page up": "pageup", "page down": "pagedown"
    ]

    private static let displayNames: [String: String] = [
        "return": "Return", "tab": "Tab", "space": "Space", "delete": "Delete", "forwarddelete": "⌦", "escape": "Escape",
        "up": "↑", "down": "↓", "left": "←", "right": "→", "home": "Home", "end": "End", "pageup": "Page Up", "pagedown": "Page Down"
    ]

    static let standaloneKeys: Set<String> = [
        "return", "tab", "space", "delete", "forwarddelete", "escape", "up", "down", "left", "right", "home", "end", "pageup", "pagedown"
    ]

    static let keyCodes: [String: CGKeyCode] = {
        var table: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
            "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
            "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
            "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
            ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash, ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote,
            "return": kVK_Return, "tab": kVK_Tab, "space": kVK_Space, "delete": kVK_Delete, "forwarddelete": kVK_ForwardDelete,
            "escape": kVK_Escape, "home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
            "left": kVK_LeftArrow, "right": kVK_RightArrow, "down": kVK_DownArrow, "up": kVK_UpArrow
        ]
        for (offset, code) in [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12].enumerated() {
            table["f\(offset + 1)"] = code
        }
        return table.mapValues { CGKeyCode($0) }
    }()
}
