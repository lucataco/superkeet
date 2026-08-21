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

    /// Whether the screen carries a camera notch. `safeAreaInsets.top > 0` is
    /// the authoritative signal (macOS 12+); falls back to a band-height
    /// heuristic when the inset is unavailable.
    static func hasCameraNotch(
        screenFrame: NSRect,
        visibleFrame: NSRect,
        topSafeInset: CGFloat = 0
    ) -> Bool {
        if topSafeInset > 0 { return true }
        return menuBandHeight(screenFrame: screenFrame, visibleFrame: visibleFrame) > 30
    }

    /// Notch metrics resolved from the screen's auxiliary top areas.
    /// When both aux areas exist, the notch is exactly the gap between them.
    struct NotchMetrics {
        let hasNotch: Bool
        let bandHeight: CGFloat
        let notchWidth: CGFloat
        let notchCenterX: CGFloat
    }

    static func notchMetrics(
        screenFrame: NSRect,
        visibleFrame: NSRect,
        topSafeInset: CGFloat,
        auxiliaryTopLeft: NSRect?,
        auxiliaryTopRight: NSRect?
    ) -> NotchMetrics {
        let bandHeight = max(
            menuBandHeight(screenFrame: screenFrame, visibleFrame: visibleFrame),
            topSafeInset
        )
        let hasNotch = hasCameraNotch(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            topSafeInset: topSafeInset
        )
        if let left = auxiliaryTopLeft, let right = auxiliaryTopRight, right.minX > left.maxX {
            return NotchMetrics(
                hasNotch: hasNotch,
                bandHeight: bandHeight,
                notchWidth: right.minX - left.maxX,
                notchCenterX: (left.maxX + right.minX) / 2
            )
        }
        return NotchMetrics(
            hasNotch: hasNotch,
            bandHeight: bandHeight,
            notchWidth: 0,
            notchCenterX: screenFrame.midX
        )
    }

    /// Top anchor beside the camera notch: inside the menu band, just right of
    /// the notch's right edge. Falls back to floating just below the menu bar
    /// on non-notched screens.
    static func islandOrigin(
        size: NSSize,
        screenFrame: NSRect,
        visibleFrame: NSRect,
        notchRightEdge: CGFloat? = nil
    ) -> NSPoint {
        let metrics = notchMetrics(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            topSafeInset: notchRightEdge == nil ? 0 : 1,
            auxiliaryTopLeft: nil,
            auxiliaryTopRight: nil
        )
        if metrics.hasNotch {
            let x = (notchRightEdge ?? screenFrame.midX + 100) + 12
            let bandHeight = metrics.bandHeight
            let y = screenFrame.maxY - bandHeight + (bandHeight - size.height) / 2
            return NSPoint(x: clampedX(x, width: size.width, screenFrame: screenFrame), y: y)
        }
        return NSPoint(
            x: screenFrame.midX - size.width / 2,
            y: visibleFrame.maxY - size.height - 12
        )
    }

    /// Frame for the wide-notch shelf: spans centered on the notch inside the
    /// menu band so the content flanks the camera. Returns the frame and the
    /// gap width the view should leave transparent over the physical notch.
    /// The window takes the full menu-band height so the pills vertically
    /// align with the menu text and the notch.
    static func notchShelfLayout(
        size: NSSize,
        screenFrame: NSRect,
        visibleFrame: NSRect,
        metrics: NotchMetrics
    ) -> (frame: NSRect, gapWidth: CGFloat) {
        guard metrics.hasNotch else {
            return (
                frame: NSRect(
                    x: screenFrame.midX - size.width / 2,
                    y: visibleFrame.maxY - size.height - 12,
                    width: size.width,
                    height: size.height
                ),
                gapWidth: 0
            )
        }
        let gapWidth = metrics.notchWidth > 0 ? metrics.notchWidth + 24 : 0
        let width = max(size.width, gapWidth + 240)
        // Full band height, anchored to the band's bottom edge (which equals
        // visibleFrame.maxY on a notched screen).
        let height = metrics.bandHeight
        let y = screenFrame.maxY - height
        let x = clampedX(metrics.notchCenterX - width / 2, width: width, screenFrame: screenFrame)
        return (frame: NSRect(x: x, y: y, width: width, height: height), gapWidth: gapWidth)
    }
}
