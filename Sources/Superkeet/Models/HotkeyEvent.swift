import CoreGraphics

struct HotkeyEvent: Sendable {
    let type: CGEventType
    let keyCode: Int64
    let flags: CGEventFlags
    let isRepeat: Bool
}
