import SwiftUI
import AppKit
import Combine

private let pointerTrackingInterval: TimeInterval = 1.0 / 15.0

/// Manages the floating recording overlay window.
/// Sizes and anchors resolve from the active `OverlayAnimationStyle`;
/// the cursor-waveform style additionally tracks the pointer.
final class RecordingOverlayWindowController: ObservableObject {
    static let shared = RecordingOverlayWindowController()

    /// Transparent gap the notch-shelf view leaves over the physical camera
    /// notch. Published so the SwiftUI view can react when the shelf moves
    /// between screens with different notch widths.
    @Published private(set) var notchGapWidth: CGFloat = 0

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

    /// Notch-adjacent styles draw in the menu-bar band, which sits above the
    /// standard `.floating` level — they must be raised to `.statusBar` or the
    /// menu bar occludes them entirely.
    static func windowLevel(for style: OverlayAnimationStyle) -> NSWindow.Level {
        switch style {
        case .gradientIsland, .notchShelf:
            return .statusBar
        case .mini, .classic, .cursorWaveform, .none:
            return .floating
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
            window.level = Self.windowLevel(for: style)
            let layout = layoutForCurrentScreen(style: style)
            notchGapWidth = layout.gapWidth
            window.setFrame(layout.frame, display: true)
            if !window.isVisible {
                window.orderFrontRegardless()
            }
            stopPointerTracking()
            startPointerTrackingIfNeeded(for: style)
            subscribeRecordingAutoHide()
            return
        }

        let overlayView = RecordingOverlayView()
        let hosting = NSHostingView(rootView: overlayView)
        self.hostingView = hosting

        let layout = layoutForCurrentScreen(style: style)
        notchGapWidth = layout.gapWidth
        hosting.frame = NSRect(origin: .zero, size: layout.frame.size)

        let window = NSPanel(
            contentRect: layout.frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        window.contentView = hosting
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = Self.windowLevel(for: style)
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = style != .cursorWaveform
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

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

        window.isMovableByWindowBackground = style != .cursorWaveform
        window.level = Self.windowLevel(for: style)
        let layout = layoutForCurrentScreen(style: style)
        notchGapWidth = layout.gapWidth
        window.setFrame(layout.frame, display: true, animate: true)
    }

    // MARK: - Positioning

    /// Full layout (frame + notch gap) for the style, resolved against the
    /// screen under the pointer — including the screen's real safe-area
    /// insets and auxiliary notch areas.
    private func layoutForCurrentScreen(style: OverlayAnimationStyle) -> (frame: NSRect, gapWidth: CGFloat) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        guard let screen else {
            return (NSRect(origin: .zero, size: Self.size(for: style)), 0)
        }
        let frame = screen.frame
        let visibleFrame = screen.visibleFrame
        let size = Self.size(for: style)
        let metrics = OverlayGeometry.notchMetrics(
            screenFrame: frame,
            visibleFrame: visibleFrame,
            topSafeInset: screen.safeAreaInsets.top,
            auxiliaryTopLeft: screen.auxiliaryTopLeftArea,
            auxiliaryTopRight: screen.auxiliaryTopRightArea
        )

        switch style {
        case .mini, .classic, .none:
            return (
                NSRect(origin: OverlayGeometry.bottomCenterOrigin(visibleFrame: visibleFrame, size: size), size: size),
                0
            )
        case .cursorWaveform:
            return (
                NSRect(
                    origin: OverlayGeometry.pointerFollowingOrigin(
                        pointer: pointer,
                        size: size,
                        screenFrame: frame,
                        visibleFrame: visibleFrame
                    ),
                    size: size
                ),
                0
            )
        case .gradientIsland:
            let notchRightEdge = metrics.notchWidth > 0
                ? metrics.notchCenterX + metrics.notchWidth / 2
                : nil
            return (
                NSRect(
                    origin: OverlayGeometry.islandOrigin(
                        size: size,
                        screenFrame: frame,
                        visibleFrame: visibleFrame,
                        notchRightEdge: notchRightEdge
                    ),
                    size: size
                ),
                0
            )
        case .notchShelf:
            return OverlayGeometry.notchShelfLayout(
                size: size,
                screenFrame: frame,
                visibleFrame: visibleFrame,
                metrics: metrics
            )
        }
    }

    // MARK: - Pointer Tracking

    /// Whether a pointer-tracking timer should be active for the style.
    /// Internal for tests — the tracker self-invalidates when this goes false.
    static func shouldTrackPointer(for style: OverlayAnimationStyle) -> Bool {
        style == .cursorWaveform
    }

    private func startPointerTrackingIfNeeded(for style: OverlayAnimationStyle) {
        guard Self.shouldTrackPointer(for: style) else { return }
        let size = Self.size(for: style)
        pointerTracker = Timer.scheduledTimer(withTimeInterval: pointerTrackingInterval, repeats: true) { [weak self] timer in
            guard let self = self, let window = self.window else { return }
            // Self-invalidate if the style changed to a non-cursor style —
            // stops runaway tracking when the user switches styles mid-recording.
            guard Self.shouldTrackPointer(for: AppSettings.shared.overlayAnimationStyle) else {
                timer.invalidate()
                self.pointerTracker = nil
                return
            }
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
