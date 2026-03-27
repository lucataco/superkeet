import SwiftUI
import AppKit
import Combine

/// Manages the floating recording overlay window.
/// Supports dynamic resizing when toggling between compact and expanded modes.
final class RecordingOverlayWindowController {
    static let shared = RecordingOverlayWindowController()

    private var window: NSWindow?
    private var hostingView: NSHostingView<RecordingOverlayView>?
    private var recordingCancellable: AnyCancellable?

    // Window sizes for each mode
    static let compactSize = NSSize(width: 260, height: 50)
    static let expandedSize = NSSize(width: 310, height: 94)

    private init() {}

    func show() {
        guard window == nil else { return }

        // Don't show overlay if user chose "none"
        let style = AppSettings.shared.recordingOverlayStyle
        guard style != "none" else { return }

        let overlayView = RecordingOverlayView()
        let hosting = NSHostingView(rootView: overlayView)
        self.hostingView = hosting

        let size = style == "classic" ? Self.expandedSize : Self.compactSize
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
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        // Position at bottom center of the main screen
        positionWindow(window, size: size)

        window.orderFrontRegardless()
        self.window = window

        // Auto-hide if recording stops unexpectedly (e.g., daemon crash)
        recordingCancellable = AppSettings.shared.$isRecording
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .filter { !$0 }
            .sink { [weak self] _ in
                self?.hide()
                // Also stop the audio monitor and reset the menu bar icon
                AudioLevelMonitor.shared.stopMonitoring()
                MenuBarManager.shared.updateMenuBarIcon(recording: false)
            }
    }

    func hide() {
        recordingCancellable?.cancel()
        recordingCancellable = nil
        window?.close()
        window = nil
        hostingView = nil
    }

    /// Animate the window resize when switching between compact and expanded modes
    func resizeForCurrentMode() {
        guard let window = window else { return }

        let style = AppSettings.shared.recordingOverlayStyle
        let newSize = style == "classic" ? Self.expandedSize : Self.compactSize

        // Calculate new frame keeping horizontal center and bottom edge stable
        let oldFrame = window.frame
        let newX = oldFrame.midX - newSize.width / 2
        let newY = oldFrame.minY  // keep bottom edge pinned
        let newFrame = NSRect(x: newX, y: newY, width: newSize.width, height: newSize.height)

        window.setFrame(newFrame, display: true, animate: true)
    }

    // MARK: - Positioning

    private func positionWindow(_ window: NSWindow, size: NSSize) {
        // Use the screen containing the mouse cursor, not NSScreen.main (which may be the wrong monitor)
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
        if let screen = screen {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - size.width / 2
            let y = screenFrame.minY + 80
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }
}
