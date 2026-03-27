import SwiftUI
import AppKit

/// Manages the NSMenu displayed from the menu bar status item
final class MenuBarManager: NSObject, ObservableObject {
    private var statusItem: NSStatusItem?
    private let parakeetService = ParakeetService.shared
    private let settings = AppSettings.shared
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Superkeet")
            button.image?.size = NSSize(width: 18, height: 18)
            button.action = #selector(menuBarClicked)
            button.target = self
        }

        updateMenu()
    }

    @objc private func menuBarClicked() {
        updateMenu()
        statusItem?.button?.performClick(nil)
    }

    private func updateMenu() {
        let menu = NSMenu()

        // Status header
        let statusText = settings.isRecording ? "Recording..." : (settings.isDaemonRunning ? "Ready" : "Daemon not running")
        let statusItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        if let font = NSFont.systemFont(ofSize: 11, weight: .medium) as NSFont? {
            statusItem.attributedTitle = NSAttributedString(
                string: statusText,
                attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
            )
        }
        menu.addItem(statusItem)
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
            startItem.isEnabled = settings.isDaemonRunning
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

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit Superkeet", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        self.statusItem?.menu = menu
    }

    // MARK: - Actions

    @objc private func startRecording() {
        parakeetService.startRecording()
        updateMenuBarIcon(recording: true)

        let style = settings.recordingOverlayStyle
        if style != "none" {
            AudioLevelMonitor.shared.startMonitoring()
            RecordingOverlayWindowController.shared.show()
        }
    }

    @objc private func stopRecording() {
        parakeetService.stopRecording()
        updateMenuBarIcon(recording: false)
        AudioLevelMonitor.shared.stopMonitoring()
        RecordingOverlayWindowController.shared.hide()
    }

    @objc private func openHistory() {
        if let existingWindow = historyWindow, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let historyView = HistoryView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: historyView)
        window.title = "Superkeet - History"
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.historyWindow = window
    }

    @objc private func openSettings() {
        if let existingWindow = settingsWindow, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 650, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: settingsView)
        window.title = "Superkeet - Settings"
        window.minSize = NSSize(width: 550, height: 400)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.settingsWindow = window
    }

    @objc private func quitApp() {
        ParakeetService.shared.cleanup()
        AudioLevelMonitor.shared.stopMonitoring()
        HotkeyManager.shared.stopListening()
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
    func toggleRecording() {
        if settings.isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    /// Called by PTT key press — only starts, never stops
    func startRecordingOnly() {
        guard !settings.isRecording else { return }
        startRecording()
    }

    /// Called by Escape key or PTT key release — only stops, never starts
    func stopRecordingOnly() {
        guard settings.isRecording else { return }
        stopRecording()
    }
}
