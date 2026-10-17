import CoreGraphics

/// Every key event Superkeet posts carries a marker so its own hotkey tap lets it through.
/// Without it, an Escape the user approved would cancel the run that pressed it.
enum SyntheticKeyEvents {
    static let marker: Int64 = 0x534B_4545

    static func events(virtualKey: CGKeyCode, flags: CGEventFlags? = nil, text: String? = nil) -> [CGEvent]? {
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: false) else { return nil }
        let units = text.map { Array($0.utf16) }
        for event in [keyDown, keyUp] {
            if let flags { event.flags = flags }
            units?.withUnsafeBufferPointer { buffer in
                event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            event.setIntegerValueField(.eventSourceUserData, value: marker)
        }
        return [keyDown, keyUp]
    }

    static func post(virtualKey: CGKeyCode, flags: CGEventFlags? = nil, text: String? = nil) -> Bool {
        guard let events = events(virtualKey: virtualKey, flags: flags, text: text) else { return false }
        events.forEach { $0.post(tap: .cghidEventTap) }
        return true
    }

    static func isSynthetic(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == marker
    }
}
