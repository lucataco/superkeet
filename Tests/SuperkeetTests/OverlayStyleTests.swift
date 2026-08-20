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

        let notchedFlag = OverlayGeometry.hasCameraNotch(
            screenFrame: NSRect(x: 0, y: 0, width: 1728, height: 1117),
            visibleFrame: NSRect(x: 0, y: 0, width: 1728, height: 1079)
        )
        XCTAssertTrue(notchedFlag)
    }

    func testIslandOriginWithinNotchBand() {
        let frame = NSRect(x: 0, y: 0, width: 1728, height: 1117)
        let visible = NSRect(x: 0, y: 0, width: 1728, height: 1079)
        let size = NSSize(width: 200, height: 40)
        let origin = OverlayGeometry.islandOrigin(size: size, screenFrame: frame, visibleFrame: visible)
        // Vertically centered on the menu band (window overlaps the band),
        // and offset right of the notch.
        XCTAssertGreaterThan(origin.y + size.height, visible.maxY)
        XCTAssertLessThan(origin.y, frame.maxY)
        XCTAssertGreaterThan(origin.x, frame.midX)
    }

    func testIslandOriginFallsBackBelowMenuOnPlainScreen() {
        let frame = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let visible = NSRect(x: 0, y: 0, width: 1920, height: 1056)
        let size = NSSize(width: 200, height: 40)
        let origin = OverlayGeometry.islandOrigin(size: size, screenFrame: frame, visibleFrame: visible)
        XCTAssertLessThan(origin.y, visible.maxY)
        XCTAssertEqual(origin.x, (1920 - 200) / 2)
    }

    func testNotchShelfOriginSpansBandOnNotchedScreen() {
        let frame = NSRect(x: 0, y: 0, width: 1728, height: 1117)
        let visible = NSRect(x: 0, y: 0, width: 1728, height: 1079)
        let size = NSSize(width: 560, height: 32)
        let origin = OverlayGeometry.notchShelfOrigin(size: size, screenFrame: frame, visibleFrame: visible)
        // Anchored at the bottom of the menu band, centered.
        XCTAssertEqual(origin.y, frame.maxY - 38, accuracy: 0.001)
        XCTAssertEqual(origin.x, (1728 - 560) / 2)
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
