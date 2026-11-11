import AppKit

/// How a global shortcut is shown beside its menu item, in the column macOS uses for key
/// equivalents. The menu only displays it; the shortcut itself is handled by `HotkeyManager`.
struct MenuKeyEquivalent: Equatable {
    let key: String
    let modifiers: NSEvent.ModifierFlags

    /// Nil for a shortcut a menu cannot draw, such as a bare modifier key (fn) or an F-key.
    init?(keyCode: Int, modifierFlags: Int) {
        let name = keyCodeName(keyCode)
        switch name {
        case "Space": key = " "
        case "Return": key = "\r"
        case "Tab": key = "\t"
        default:
            guard name.count == 1 else { return nil }
            key = name.lowercased()
        }
        let flags = CGEventFlags(rawValue: UInt64(modifierFlags))
        var modifiers: NSEvent.ModifierFlags = []
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        self.modifiers = modifiers
    }

    func apply(to item: NSMenuItem) {
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = modifiers
    }
}
