import AppKit
import SwiftUI

/// One Setup window for first launch and for "Run Setup Again...".
@MainActor
final class SetupWindowSession: NSObject {
    static let shared = SetupWindowSession()

    private var windowController: NSWindowController?

    private override init() {
        super.init()
    }

    func present(onComplete: @escaping () -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        if let existing = windowController?.window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(rootView: OnboardingView(onComplete: onComplete))
        let window = NSWindow(contentViewController: hostingController)
        window.setContentSize(NSSize(width: 560, height: 580))
        window.styleMask = [.titled, .closable, .resizable]
        window.title = "Superkeet Setup"
        window.minSize = NSSize(width: 560, height: 580)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        windowController = NSWindowController(window: window)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose),
            name: NSWindow.willCloseNotification,
            object: window
        )
    }

    func close() {
        dispatchPrecondition(condition: .onQueue(.main))
        windowController?.window?.close()
        windowController = nil
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === windowController?.window else { return }
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.windowController?.window === window else { return }
            self.windowController = nil
        }
    }
}
