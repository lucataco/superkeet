import SwiftUI
import AppKit

/// Manages the NSMenu displayed from the menu bar status item
final class MenuBarManager: NSObject, ObservableObject, NSMenuDelegate {
    static let shared = MenuBarManager()

    private var statusItem: NSStatusItem?
    private let parakeetService = ParakeetService.shared
    private let settings = AppSettings.shared
    private let hotkeyManager = HotkeyManager.shared
    private var settingsWindowController: NSWindowController?
    private var historyWindowController: NSWindowController?
    private var onboardingWindowController: NSWindowController?
    private var recordingRequested: Bool = false

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Superkeet")
            button.image?.size = NSSize(width: 18, height: 18)
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem?.menu = menu
    }

    /// Rebuilds all menu items. Called by NSMenuDelegate before each display.
    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        // Status header
        let statusText: String
        if settings.isRecording {
            statusText = "Recording..."
        } else if !hotkeyManager.isListening {
            statusText = "Hotkeys not active — grant Accessibility"
        } else if !settings.isDaemonRunning {
            statusText = "Daemon not running"
        } else {
            statusText = "Ready"
        }
        let statusItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        let statusColor: NSColor = hotkeyManager.isListening ? .secondaryLabelColor : .systemOrange
        if let font = NSFont.systemFont(ofSize: 11, weight: .medium) as NSFont? {
            statusItem.attributedTitle = NSAttributedString(
                string: statusText,
                attributes: [.font: font, .foregroundColor: statusColor]
            )
        }
        menu.addItem(statusItem)

        // Show accessibility help item when hotkeys are not active
        if !hotkeyManager.isListening {
            let helpItem = NSMenuItem(title: "Open Accessibility Settings...", action: #selector(openAccessibilitySettings), keyEquivalent: "")
            helpItem.target = self
            helpItem.image = NSImage(systemSymbolName: "lock.open", accessibilityDescription: "Accessibility")
            menu.addItem(helpItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Start/Stop Recording
        if settings.isRecording {
            let stopItem = NSMenuItem(title: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "")
            stopItem.target = self
            stopItem.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop")
            menu.addItem(stopItem)
        } else {
            let startItem = NSMenuItem(title: "Start Recording", action: #selector(startRecording), keyEquivalent: "")
            startItem.target = self
            startItem.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Record")
            startItem.isEnabled = !recordingRequested
            menu.addItem(startItem)
        }

        menu.addItem(NSMenuItem.separator())

        // History
        let historyItem = NSMenuItem(title: "History", action: #selector(openHistory), keyEquivalent: "h")
        historyItem.target = self
        historyItem.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "History")
        menu.addItem(historyItem)

        // Settings
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
        menu.addItem(settingsItem)

        // Run Setup
        let setupItem = NSMenuItem(title: "Run Setup Again...", action: #selector(runSetupAgain), keyEquivalent: "")
        setupItem.target = self
        setupItem.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "Setup")
        menu.addItem(setupItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit Superkeet", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu(menu)
    }

    // MARK: - Actions

    @MainActor
    @objc private func startRecording() {
        guard !recordingRequested else { return }
        recordingRequested = true
        updateMenuBarIcon(recording: false)

        Task { @MainActor in
            await self.startRecordingFlow()
        }
    }

    @MainActor
    private func startRecordingFlow() async {
        do {
            if !settings.isDaemonRunning {
                try await parakeetService.startDaemon()
            }
        } catch {
            print("[MenuBar] Failed to restart daemon for recording: \(error)")
            resetRecordingUI()
            return
        }

        guard recordingRequested else { return }

        let started = await parakeetService.startRecording()
        guard started else {
            resetRecordingUI()
            return
        }

        guard recordingRequested else {
            parakeetService.stopRecording()
            return
        }

        updateMenuBarIcon(recording: true)

        let style = settings.recordingOverlayStyle
        if style != "none" {
            AudioLevelMonitor.shared.startMonitoring()
            RecordingOverlayWindowController.shared.show()
        }
    }

    @MainActor
    private func resetRecordingUI() {
        recordingRequested = false
        updateMenuBarIcon(recording: false)
        AudioLevelMonitor.shared.stopMonitoring()
        RecordingOverlayWindowController.shared.hide()
    }

    @MainActor
    @objc private func stopRecording() {
        recordingRequested = false
        parakeetService.stopRecording()
        updateMenuBarIcon(recording: false)
        AudioLevelMonitor.shared.stopMonitoring()
        RecordingOverlayWindowController.shared.hide()
    }

    @MainActor
    @objc private func cancelRecording() {
        recordingRequested = false
        parakeetService.cancelRecording()
        updateMenuBarIcon(recording: false)
        AudioLevelMonitor.shared.stopMonitoring()
        RecordingOverlayWindowController.shared.hide()
    }

    @objc private func openHistory() {
        if let existingWindow = historyWindowController?.window, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(rootView: HistoryView())
        let window = NSWindow(contentViewController: hostingController)
        window.setContentSize(NSSize(width: 480, height: 520))
        window.styleMask = [.titled, .closable, .resizable]
        window.title = "Superkeet - History"
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let controller = NSWindowController(window: window)
        self.historyWindowController = controller

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(historyWindowWillClose),
            name: NSWindow.willCloseNotification,
            object: window
        )
    }

    @objc private func historyWindowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === historyWindowController?.window else { return }
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.historyWindowController?.window === window else { return }
            self.historyWindowController = nil
        }
    }

    @objc func openSettings() {
        if let existingWindow = settingsWindowController?.window, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hostingController)
        window.setContentSize(NSSize(width: 650, height: 480))
        window.styleMask = [.titled, .closable, .resizable]
        window.title = "Superkeet - Settings"
        window.minSize = NSSize(width: 550, height: 400)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let controller = NSWindowController(window: window)
        self.settingsWindowController = controller

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsWindowWillClose),
            name: NSWindow.willCloseNotification,
            object: window
        )
    }

    @objc private func settingsWindowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindowController?.window else { return }
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.settingsWindowController?.window === window else { return }
            self.settingsWindowController = nil
        }
    }

    @objc private func runSetupAgain() {
        if let existingWindow = onboardingWindowController?.window, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let onboardingView = OnboardingView { [weak self] in
            // On completion, just close the window (daemon is already running)
            self?.onboardingWindowController?.window?.close()
            self?.onboardingWindowController = nil
            NSApp.setActivationPolicy(.accessory)
        }

        let hostingController = NSHostingController(rootView: onboardingView)
        let window = NSWindow(contentViewController: hostingController)
        window.setContentSize(NSSize(width: 560, height: 580))
        window.styleMask = [.titled, .closable, .resizable]
        window.title = "Superkeet Setup"
        window.minSize = NSSize(width: 560, height: 580)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let controller = NSWindowController(window: window)
        self.onboardingWindowController = controller

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(runSetupWindowWillClose),
            name: NSWindow.willCloseNotification,
            object: window
        )
    }

    @objc private func runSetupWindowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === onboardingWindowController?.window else { return }
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.onboardingWindowController?.window === window else { return }
            self.onboardingWindowController = nil
        }
    }

    @objc private func openAccessibilitySettings() {
        _ = hotkeyManager.checkAccessibility()
        SystemSettingsLinks.openAccessibility()
        hotkeyManager.accessibilityGranted = hotkeyManager.checkAccessibilitySilently()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - UI Updates

    func updateMenuBarIcon(recording: Bool) {
        if recording {
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            if let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Superkeet - Recording")?
                .withSymbolConfiguration(config) {
                image.size = NSSize(width: 16, height: 18)
                image.isTemplate = false  // Use our red color, not menu bar template rendering
                statusItem?.button?.image = image
            }
            statusItem?.button?.contentTintColor = nil
        } else {
            let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Superkeet")
            image?.size = NSSize(width: 18, height: 18)
            // isTemplate defaults to true — adapts to light/dark automatically
            statusItem?.button?.image = image
            statusItem?.button?.contentTintColor = nil
        }
    }

    /// Called by the hotkey manager to toggle recording
    @MainActor
    func toggleRecording() {
        if settings.isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    /// Called by PTT key press — only starts, never stops
    @MainActor
    func startRecordingOnly() {
        guard !settings.isRecording && !recordingRequested else { return }
        startRecording()
    }

    /// Called by Escape key or PTT key release — only stops, never starts
    @MainActor
    func stopRecordingOnly() {
        guard settings.isRecording || recordingRequested else { return }
        stopRecording()
    }

    /// Called by Escape key — cancels without asking the daemon to transcribe.
    @MainActor
    func cancelRecordingOnly() {
        guard settings.isRecording || recordingRequested else { return }
        cancelRecording()
    }
}
