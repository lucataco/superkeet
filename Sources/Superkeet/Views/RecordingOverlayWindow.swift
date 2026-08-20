import SwiftUI
import AppKit
import Combine

private let pointerTrackingInterval: TimeInterval = 1.0 / 15.0

/// Manages the floating recording overlay window.
/// Sizes and anchors resolve from the active `OverlayAnimationStyle`;
/// the cursor-waveform style additionally tracks the pointer.
final class RecordingOverlayWindowController {
    static let shared = RecordingOverlayWindowController()

    private var window: NSWindow?
    private var hostingView: NSHostingView<RecordingOverlayView>?
    private var recordingCancellable: AnyCancellable?
    private var pointerTracker: Timer?

    private init() {}

    // MARK: - Style Sizing

    static let compactSize = NSSize(width: 260, height: 50)
    static let expandedSize = NSSize(width: 310, height: 94)
    static let cursorWaveformSize = NSSize(width: 248, height: 44)
    static let gradientIslandSize = NSSize(width: 200, height: 40)
    static let notchShelfSize = NSSize(width: 560, height: 32)

    static func size(for style: OverlayAnimationStyle) -> NSSize {
        switch style {
        case .mini: return compactSize
        case .classic: return expandedSize
        case .cursorWaveform: return cursorWaveformSize
        case .gradientIsland: return gradientIslandSize
        case .notchShelf: return notchShelfSize
        case .none: return .zero
        }
    }

    // MARK: - Show / Hide

    func show() {
        dispatchPrecondition(condition: .onQueue(.main))

        let style = AppSettings.shared.overlayAnimationStyle
        guard style.showsOverlay else { return }

        if let window {
        // Reuse the panel: re-anchor it for the current session (screen may
        // have changed) and re-order it — NSPanel + NSHostingView + the
        // SwiftUI tree are expensive to rebuild per recording.
            window.isMovableByWindowBackground = style != .cursorWaveform
            if !window.isVisible {
                window.setFrame(
                    NSRect(origin: anchorOrigin(for: style, size: Self.size(for: style)), size: Self.size(for: style)),
                    display: true
                )
                window.orderFrontRegardless()
            }
            startPointerTrackingIfNeeded(for: style)
            subscribeRecordingAutoHide()
            return
        }

        let overlayView = RecordingOverlayView()
        let hosting = NSHostingView(rootView: overlayView)
        self.hostingView = hosting

        let size = Self.size(for: style)
        hosting.frame = NSRect(origin: .zero, size: size)

        let window = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        window.contentView = hosting
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = style != .cursorWaveform
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        positionWindow(window, style: style, size: size)

        window.orderFrontRegardless()
        self.window = window

        startPointerTrackingIfNeeded(for: style)
        subscribeRecordingAutoHide()
    }

    func hide() {
        dispatchPrecondition(condition: .onQueue(.main))
        stopPointerTracking()
        recordingCancellable?.cancel()
        recordingCancellable = nil
        // Keep the panel alive — just order it out. The next show() re-anchors
        // and re-orders without rebuilding the SwiftUI hierarchy.
        window?.orderOut(nil)
    }

    // MARK: - Auto-hide subscription

    private func subscribeRecordingAutoHide() {
        guard recordingCancellable == nil else { return }
        // Auto-hide if recording stops unexpectedly (e.g., daemon crash)
        recordingCancellable = AppSettings.shared.$isRecording
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .filter { !$0 }
            .sink { [weak self] _ in
                self?.hide()
                AudioLevelMonitor.shared.stopMonitoring()
                MenuBarManager.shared.updateMenuBarIcon(recording: false)
            }
    }

    // MARK: - Resize

    /// Animate the window resize/reposition when the style changes.
    func resizeForCurrentMode() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let window = window else { return }

        let style = AppSettings.shared.overlayAnimationStyle
        if !style.showsOverlay {
            hide()
            return
        }
        stopPointerTracking()
        startPointerTrackingIfNeeded(for: style)

        let newSize = Self.size(for: style)
        let origin = anchorOrigin(for: style, size: newSize)
        let newFrame = NSRect(origin: origin, size: newSize)
        window.setFrame(newFrame, display: true, animate: true)
    }

    // MARK: - Positioning

    private func positionWindow(_ window: NSWindow, style: OverlayAnimationStyle, size: NSSize) {
        let origin = anchorOrigin(for: style, size: size)
        window.setFrameOrigin(origin)
    }

    /// Anchor origin for a style, resolved against the screen under the mouse.
    private func anchorOrigin(for style: OverlayAnimationStyle, size: NSSize) -> NSPoint {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        guard let screen else {
            return .zero
        }
        let frame = screen.frame
        let visibleFrame = screen.visibleFrame

        switch style {
        case .mini, .classic:
            return OverlayGeometry.bottomCenterOrigin(visibleFrame: visibleFrame, size: size)
        case .cursorWaveform:
            return OverlayGeometry.pointerFollowingOrigin(
                pointer: pointer,
                size: size,
                screenFrame: frame,
                visibleFrame: visibleFrame
            )
        case .gradientIsland:
            return OverlayGeometry.islandOrigin(
                size: size,
                screenFrame: frame,
                visibleFrame: visibleFrame
            )
        case .notchShelf:
            return OverlayGeometry.notchShelfOrigin(
                size: size,
                screenFrame: frame,
                visibleFrame: visibleFrame
            )
        case .none:
            return OverlayGeometry.bottomCenterOrigin(visibleFrame: visibleFrame, size: size)
        }
    }

    // MARK: - Pointer Tracking

    private func startPointerTrackingIfNeeded(for style: OverlayAnimationStyle) {
        guard style == .cursorWaveform else { return }
        let size = Self.size(for: style)
        pointerTracker = Timer.scheduledTimer(withTimeInterval: pointerTrackingInterval, repeats: true) { [weak self] _ in
            guard let self = self, let window = self.window else { return }
            let pointer = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
            guard let screen else { return }
            let origin = OverlayGeometry.pointerFollowingOrigin(
                pointer: pointer,
                size: size,
                screenFrame: screen.frame,
                visibleFrame: screen.visibleFrame
            )
            if origin != window.frame.origin {
                window.setFrameOrigin(origin)
            }
        }
    }

    private func stopPointerTracking() {
        pointerTracker?.invalidate()
        pointerTracker = nil
    }
}
