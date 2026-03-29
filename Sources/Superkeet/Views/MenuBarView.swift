import SwiftUI
import AppKit

/// Manages the NSMenu displayed from the menu bar status item
final class MenuBarManager: NSObject, ObservableObject, NSMenuDelegate {
    static let shared = MenuBarManager()

    private var statusItem: NSStatusItem?
    private let parakeetService = ParakeetService.shared
    private let settings = AppSettings.shared
    private let hotkeyManager = HotkeyManager.shared
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var onboardingWindow: NSWindow?

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

    @objc private func startRecording() {
        // If daemon was stopped (e.g., idle timeout), restart it first
        if !settings.isDaemonRunning {
            updateMenuBarIcon(recording: false)
            Task {
                do {
                    try await parakeetService.startDaemon()
                    await MainActor.run { self.performStartRecording() }
                } catch {
                    print("[MenuBar] Failed to restart daemon for recording: \(error)")
                }
            }
            return
        }
        performStartRecording()
    }

    private func performStartRecording() {
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

    @objc func openSettings() {
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

    @objc private func runSetupAgain() {
        if let existingWindow = onboardingWindow, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let onboardingView = OnboardingView {
            // On completion, just close the window (daemon is already running)
            self.onboardingWindow?.close()
            self.onboardingWindow = nil
            NSApp.setActivationPolicy(.accessory)
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: onboardingView)
        window.title = "Superkeet Setup"
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.onboardingWindow = window
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        // Re-prompt via AXIsProcessTrustedWithOptions
        hotkeyManager.checkAccessibility()
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
