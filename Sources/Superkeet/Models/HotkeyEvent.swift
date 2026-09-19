import CoreGraphics

/// Copy the keyboard fields before entering the main actor; the event tap keeps
/// ownership of the original, non-Sendable CGEvent and returns it unchanged.
struct HotkeyEvent: Sendable {
    let type: CGEventType
    let keyCode: Int64
    let flags: CGEventFlags
    let isRepeat: Bool
}
