import XCTest
import AppKit
@testable import Superkeet

final class OverlayStyleTests: XCTestCase {

    // MARK: - OverlayAnimationStyle resolution

    func testResolvesAllRawValues() {
        XCTAssertEqual(OverlayAnimationStyle.resolve("mini"), .mini)
        XCTAssertEqual(OverlayAnimationStyle.resolve("classic"), .classic)
        XCTAssertEqual(OverlayAnimationStyle.resolve("cursorWaveform"), .cursorWaveform)
        XCTAssertEqual(OverlayAnimationStyle.resolve("gradientIsland"), .gradientIsland)
        XCTAssertEqual(OverlayAnimationStyle.resolve("notchShelf"), .notchShelf)
        XCTAssertEqual(OverlayAnimationStyle.resolve("none"), .none)
    }

    func testUnknownValueFallsBackToMini() {
        XCTAssertEqual(OverlayAnimationStyle.resolve("bogus"), .mini)
        XCTAssertEqual(OverlayAnimationStyle.resolve(""), .mini)
    }

    func testNoneIsTheOnlyStyleThatHidesOverlay() {
        for style in OverlayAnimationStyle.allCases {
            XCTAssertEqual(style.showsOverlay, style != .none)
        }
    }

    // MARK: - CaptureSoundStyle mapping

    func testSoundPlayerUsesBrevitySafeSystemSounds() {
        XCTAssertEqual(CaptureSoundPlayer.soundName(for: .start), "Tink")
        XCTAssertEqual(CaptureSoundPlayer.soundName(for: .stop), "Pop")
    }

    // MARK: - Geometry

    func testBottomCenterOrigin() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 876)
        let size = NSSize(width: 260, height: 50)
        let origin = OverlayGeometry.bottomCenterOrigin(visibleFrame: visible, size: size)
        XCTAssertEqual(origin.x, (1440 - 260) / 2)
        XCTAssertEqual(origin.y, 80)
    }

    func testPointerOriginClampsLeftEdge() {
        let frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = OverlayGeometry.clampedX(-50, width: 248, screenFrame: frame)
        XCTAssertEqual(origin, 0)
    }

    func testPointerOriginClampsRightEdge() {
        let frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = OverlayGeometry.clampedX(1400, width: 248, screenFrame: frame)
        XCTAssertEqual(origin, 1440 - 248)
    }

    func testMenuBandDetection() {
        // Notched laptop: menu band is taller than the classic 24 px bar.
        let notched = OverlayGeometry.menuBandHeight(
            screenFrame: NSRect(x: 0, y: 0, width: 1728, height: 1117),
            visibleFrame: NSRect(x: 0, y: 0, width: 1728, height: 1079)
        )
        XCTAssertEqual(notched, 38)

        // Plain external display: classic 24 px menu bar, no notch.
        let plain = OverlayGeometry.hasCameraNotch(
            screenFrame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: NSRect(x: 0, y: 0, width: 1920, height: 1056)
        )
        XCTAssertFalse(plain)

        // safeAreaInsets.top > 0 is the authoritative notch signal.
        let notchedByInset = OverlayGeometry.hasCameraNotch(
            screenFrame: NSRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: NSRect(x: 0, y: 0, width: 1512, height: 945),
            topSafeInset: 37
        )
        XCTAssertTrue(notchedByInset)
    }

    func testNotchMetricsFromAuxiliaryAreas() {
        // 14" MacBook Pro: 1512x982 logical, ~184pt notch centered.
        let frame = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = NSRect(x: 0, y: 0, width: 1512, height: 945)
        let auxLeft = NSRect(x: 0, y: 945, width: 664, height: 37)
        let auxRight = NSRect(x: 848, y: 945, width: 664, height: 37)

        let metrics = OverlayGeometry.notchMetrics(
            screenFrame: frame,
            visibleFrame: visible,
            topSafeInset: 37,
            auxiliaryTopLeft: auxLeft,
            auxiliaryTopRight: auxRight
        )
        XCTAssertTrue(metrics.hasNotch)
        XCTAssertEqual(metrics.bandHeight, 37)
        XCTAssertEqual(metrics.notchWidth, 184, accuracy: 0.001)
        XCTAssertEqual(metrics.notchCenterX, 756, accuracy: 0.001)
    }

    func testNotchMetricsWithoutNotch() {
        let frame = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let visible = NSRect(x: 0, y: 0, width: 1920, height: 1056)
        let metrics = OverlayGeometry.notchMetrics(
            screenFrame: frame,
            visibleFrame: visible,
            topSafeInset: 0,
            auxiliaryTopLeft: nil,
            auxiliaryTopRight: nil
        )
        XCTAssertFalse(metrics.hasNotch)
        XCTAssertEqual(metrics.notchWidth, 0)
    }

    func testIslandOriginWithinNotchBand() {
        let frame = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = NSRect(x: 0, y: 0, width: 1512, height: 945)
        let size = NSSize(width: 200, height: 40)
        let origin = OverlayGeometry.islandOrigin(
            size: size,
            screenFrame: frame,
            visibleFrame: visible,
            notchRightEdge: 940
        )
        // Just right of the notch's right edge, vertically centered in the band.
        XCTAssertEqual(origin.x, 952)
        XCTAssertEqual(origin.y + size.height / 2, frame.maxY - 37 / 2, accuracy: 0.001)
    }

    func testIslandOriginFallsBackBelowMenuOnPlainScreen() {
        let frame = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let visible = NSRect(x: 0, y: 0, width: 1920, height: 1056)
        let size = NSSize(width: 200, height: 40)
        let origin = OverlayGeometry.islandOrigin(size: size, screenFrame: frame, visibleFrame: visible)
        XCTAssertLessThan(origin.y, visible.maxY)
        XCTAssertEqual(origin.x, (1920 - 200) / 2)
    }

    func testNotchShelfLayoutSpansNotchBand() {
        let frame = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = NSRect(x: 0, y: 0, width: 1512, height: 945)
        let auxLeft = NSRect(x: 0, y: 945, width: 664, height: 37)
        let auxRight = NSRect(x: 848, y: 945, width: 664, height: 37)
        let metrics = OverlayGeometry.notchMetrics(
            screenFrame: frame,
            visibleFrame: visible,
            topSafeInset: 37,
            auxiliaryTopLeft: auxLeft,
            auxiliaryTopRight: auxRight
        )
        let layout = OverlayGeometry.notchShelfLayout(
            size: NSSize(width: 560, height: 32),
            screenFrame: frame,
            visibleFrame: visible,
            metrics: metrics
        )
        // Window spans the full menu band height, bottom-anchored to the band.
        XCTAssertEqual(layout.frame.minY, frame.maxY - metrics.bandHeight, accuracy: 0.001)
        XCTAssertEqual(layout.frame.height, metrics.bandHeight, accuracy: 0.001)
        // Centered on the notch, gap covers the notch.
        XCTAssertEqual(layout.frame.midX, 756, accuracy: 0.001)
        XCTAssertEqual(layout.gapWidth, 208, accuracy: 0.001) // 184 notch + 24 padding
        XCTAssertGreaterThan(layout.frame.width, layout.gapWidth)
    }

    func testNotchShelfLayoutOnPlainScreenHasNoGap() {
        let frame = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let visible = NSRect(x: 0, y: 0, width: 1920, height: 1056)
        let metrics = OverlayGeometry.notchMetrics(
            screenFrame: frame,
            visibleFrame: visible,
            topSafeInset: 0,
            auxiliaryTopLeft: nil,
            auxiliaryTopRight: nil
        )
        let layout = OverlayGeometry.notchShelfLayout(
            size: NSSize(width: 560, height: 32),
            screenFrame: frame,
            visibleFrame: visible,
            metrics: metrics
        )
        XCTAssertEqual(layout.gapWidth, 0)
        XCTAssertLessThan(layout.frame.maxY, visible.maxY)
    }

    // MARK: - Window level gating

    func testNotchStylesDrawAboveMenuBar() {
        XCTAssertEqual(RecordingOverlayWindowController.windowLevel(for: .notchShelf), .statusBar)
        XCTAssertEqual(RecordingOverlayWindowController.windowLevel(for: .gradientIsland), .statusBar)
        XCTAssertEqual(RecordingOverlayWindowController.windowLevel(for: .mini), .floating)
        XCTAssertEqual(RecordingOverlayWindowController.windowLevel(for: .classic), .floating)
        XCTAssertEqual(RecordingOverlayWindowController.windowLevel(for: .cursorWaveform), .floating)
        XCTAssertEqual(RecordingOverlayWindowController.windowLevel(for: .none), .floating)
    }

    func testNotchStylesIgnoreMouseEvents() {
        XCTAssertTrue(RecordingOverlayWindowController.ignoresMouseEvents(for: .notchShelf))
        XCTAssertTrue(RecordingOverlayWindowController.ignoresMouseEvents(for: .gradientIsland))
        XCTAssertFalse(RecordingOverlayWindowController.ignoresMouseEvents(for: .mini))
        XCTAssertFalse(RecordingOverlayWindowController.ignoresMouseEvents(for: .classic))
        XCTAssertFalse(RecordingOverlayWindowController.ignoresMouseEvents(for: .cursorWaveform))
        XCTAssertFalse(RecordingOverlayWindowController.ignoresMouseEvents(for: .none))
    }

    // MARK: - Pointer tracking gating

    func testOnlyCursorWaveformTracksPointer() {
        XCTAssertTrue(RecordingOverlayWindowController.shouldTrackPointer(for: .cursorWaveform))
        for style in OverlayAnimationStyle.allCases where style != .cursorWaveform {
            XCTAssertFalse(
                RecordingOverlayWindowController.shouldTrackPointer(for: style),
                "\(style) must not track the pointer"
            )
        }
    }
}
