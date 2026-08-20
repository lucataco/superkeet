import AppKit

/// Pure geometry for recording-overlay placement. Extracted from the window
/// controller so anchoring and clamping rules are directly testable.
enum OverlayGeometry {

    /// Standard bottom anchor: horizontally centered on the screen's usable
    /// area, lifted from the bottom edge.
    static func bottomCenterOrigin(visibleFrame: NSRect, size: NSSize) -> NSPoint {
        NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.minY + 80
        )
    }

    /// Pointer-following anchor: window tracks the pointer horizontally,
    /// clamped so the whole window stays on the screen.
    static func pointerFollowingOrigin(
        pointer: NSPoint,
        size: NSSize,
        screenFrame: NSRect,
        visibleFrame: NSRect
    ) -> NSPoint {
        let rawX = pointer.x - size.width / 2
        return NSPoint(
            x: clampedX(rawX, width: size.width, screenFrame: screenFrame),
            y: visibleFrame.minY + 80
        )
    }

    /// Clamp x so the window stays within the screen frame.
    static func clampedX(_ x: CGFloat, width: CGFloat, screenFrame: NSRect) -> CGFloat {
        min(max(x, screenFrame.minX), screenFrame.maxX - width)
    }

    /// Height of the top menu-bar band (difference between full frame and
    /// visible frame). On notched MacBooks this band holds the camera notch.
    static func menuBandHeight(screenFrame: NSRect, visibleFrame: NSRect) -> CGFloat {
        max(0, screenFrame.maxY - visibleFrame.maxY)
    }

    /// Whether the screen carries a camera notch (menu band taller than the
    /// classic 24 px menu bar).
    static func hasCameraNotch(screenFrame: NSRect, visibleFrame: NSRect) -> Bool {
        menuBandHeight(screenFrame: screenFrame, visibleFrame: visibleFrame) > 30
    }

    /// Top anchor beside the camera notch: inside the menu band, offset right
    /// of the notch. Falls back to floating just below the menu bar on
    /// non-notched screens.
    static func islandOrigin(
        size: NSSize,
        screenFrame: NSRect,
        visibleFrame: NSRect,
        notchOffset: CGFloat = 108
    ) -> NSPoint {
        let bandHeight = menuBandHeight(screenFrame: screenFrame, visibleFrame: visibleFrame)
        if hasCameraNotch(screenFrame: screenFrame, visibleFrame: visibleFrame) {
            let x = screenFrame.midX + notchOffset
            let y = screenFrame.maxY - (bandHeight + size.height) / 2
            return NSPoint(x: clampedX(x, width: size.width, screenFrame: screenFrame), y: y)
        }
        return NSPoint(
            x: screenFrame.midX - size.width / 2,
            y: visibleFrame.maxY - size.height - 12
        )
    }

    /// Top anchor spanning the notch band: centered horizontally across the
    /// whole band so the left/right bar clusters frame the camera.
    static func notchShelfOrigin(
        size: NSSize,
        screenFrame: NSRect,
        visibleFrame: NSRect
    ) -> NSPoint {
        let bandHeight = menuBandHeight(screenFrame: screenFrame, visibleFrame: visibleFrame)
        let y: CGFloat = hasCameraNotch(screenFrame: screenFrame, visibleFrame: visibleFrame)
            ? screenFrame.maxY - bandHeight
            : visibleFrame.maxY - size.height - 12
        return NSPoint(
            x: screenFrame.midX - size.width / 2,
            y: y
        )
    }
}
