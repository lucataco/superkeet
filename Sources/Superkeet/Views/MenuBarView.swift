import SwiftUI
import AppKit
import Combine
import os.log

private let menuBarLog = Logger(subsystem: "com.superkeet.app", category: "MenuBar")

final class MenuBarManager: NSObject, ObservableObject, NSMenuDelegate {
    static let shared = MenuBarManager()

    private var statusItem: NSStatusItem?
    private let parakeetService = ParakeetService.shared
    private let settings = AppSettings.shared
    private let hotkeyManager = HotkeyManager.shared
    private var settingsWindowController: NSWindowController?
    private var historyWindowController: NSWindowController?
    private var onboardingWindowController: NSWindowController?
    private let recordingStart = RecordingStartCoordinator()
    private var recordingRequested: Bool { recordingStart.requestID != nil }
    private var pttSessionActive: Bool = false
    private var recordingStateCancellable: AnyCancellable?
    private var sessionStatusCancellable: AnyCancellable?
    private var statusClearTask: DispatchWorkItem?

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Superkeet")
            button.image?.size = NSSize(width: 18, height: 18)
        }

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem?.menu = menu

        recordingStateCancellable = settings.$isRecording
            .scan((false, false)) { ($0.1, $1) }
            .filter { $0.0 && !$0.1 }
            .map { [weak self] _ in self?.recordingStart.requestID }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] requestID in
                guard let self, self.recordingStart.requestID == requestID else { return }
                self.recordingStart.cancel()
                self.pttSessionActive = false
                self.updateMenuBarIcon(recording: false)
                AudioLevelMonitor.shared.stopMonitoring()
                RecordingOverlayWindowController.shared.hide()
            }

        sessionStatusCancellable = parakeetService.$sessionStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in self?.showSessionStatus(status) }
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let statusText: String
        if parakeetService.daemonState == .transcribing {
            statusText = "Transcribing…"
        } else if settings.isRecording {
            statusText = "Recording..."
        } else if !hotkeyManager.isListening {
            statusText = "Hotkeys not active — grant Accessibility"
        } else if !settings.isDaemonRunning {
            statusText = "Daemon not running"
        } else {
            statusText = parakeetService.sessionStatus
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

        if !hotkeyManager.isListening {
            let helpItem = NSMenuItem(title: "Open Accessibility Settings...", action: #selector(openAccessibilitySettings), keyEquivalent: "")
            helpItem.target = self
            helpItem.image = NSImage(systemSymbolName: "lock.open", accessibilityDescription: "Accessibility")
            menu.addItem(helpItem)
        }

        menu.addItem(NSMenuItem.separator())

        if settings.isRecording {
            let stopItem = NSMenuItem(title: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "")
            stopItem.target = self
            stopItem.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop")
            menu.addItem(stopItem)
        } else if recordingRequested {
            let cancelItem = NSMenuItem(title: "Cancel Starting Recording", action: #selector(cancelRecording), keyEquivalent: "")
            cancelItem.target = self
            menu.addItem(cancelItem)
        } else {
            let startItem = NSMenuItem(title: "Start Recording", action: #selector(startRecording), keyEquivalent: "")
            startItem.target = self
            startItem.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Record")
            startItem.isEnabled = !recordingRequested && parakeetService.daemonState != .transcribing
            menu.addItem(startItem)
        }

        menu.addItem(NSMenuItem.separator())

        addRecoveryItems(to: menu)

        let historyItem = NSMenuItem(title: "History", action: #selector(openHistory), keyEquivalent: "h")
        historyItem.target = self
        historyItem.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "History")
        menu.addItem(historyItem)

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
        menu.addItem(settingsItem)

        let setupItem = NSMenuItem(title: "Run Setup Again...", action: #selector(runSetupAgain), keyEquivalent: "")
        setupItem.target = self
        setupItem.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "Setup")
        menu.addItem(setupItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Superkeet", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu(menu)
    }

    private func addRecoveryItems(to menu: NSMenu) {
        let actions: [(String, Selector, Bool)] = [
            ("Copy Last Transcript", #selector(copyLastTranscript), !parakeetService.lastTranscription.isEmpty),
            ("Copy Original Transcript", #selector(copyOriginalTranscript), !parakeetService.lastRawTranscription.isEmpty),
            ("Undo Text Changes and Copy", #selector(undoTextChanges), parakeetService.canUndoTextChanges)
        ]
        for (title, action, enabled) in actions {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            menu.addItem(item)
        }
        menu.addItem(.separator())
    }

    @objc private func copyLastTranscript() {
        PasteService.shared.copyToClipboard(parakeetService.lastTranscription)
    }

    @objc private func copyOriginalTranscript() {
        PasteService.shared.copyToClipboard(parakeetService.lastRawTranscription)
    }

    @objc private func undoTextChanges() {
        parakeetService.undoLastTextChanges()
    }

    private func showSessionStatus(_ status: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        statusClearTask?.cancel()
        guard let button = statusItem?.button else { return }
        let isPartial = status.hasPrefix("Partial transcript")
        button.title = status == "Ready" || status == "Recording…" ? "" : " " + (isPartial ? "Partial transcript" : status)
        button.toolTip = status
        button.setAccessibilityLabel("Superkeet: \(status)")
        NSAccessibility.post(element: button, notification: .announcementRequested, userInfo: [
            .announcement: status, .priority: NSAccessibilityPriorityLevel.high.rawValue
        ])
        if status == "Transcription complete" || status == "No speech detected" || status == "Recording cancelled" {
            let task = DispatchWorkItem { [weak button] in button?.title = "" }
            statusClearTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: task)
        }
    }

    @MainActor
    @objc private func startRecording() {
        guard parakeetService.daemonState != .transcribing, let requestID = recordingStart.begin() else { return }
        updateMenuBarIcon(recording: false)

        Task { @MainActor in
            await self.startRecordingFlow(requestID: requestID)
        }
    }

    @MainActor
    private func startRecordingFlow(requestID: UUID) async {
        let started: Bool
        do {
            started = try await recordingStart.run(requestID, prepare: {
                if !self.settings.isDaemonRunning {
                    try await self.parakeetService.startDaemon()
                }
            }, start: {
                await self.parakeetService.startRecording()
            })
        } catch {
            menuBarLog.error("Failed to restart daemon for recording: \(error.localizedDescription)")
            guard recordingStart.isCurrent(requestID) else { return }
            teardownRecordingUI()
            return
        }

        guard recordingStart.isCurrent(requestID) else {
            if started { parakeetService.cancelRecording() }
            return
        }
        guard started else {
            teardownRecordingUI()
            return
        }

        updateMenuBarIcon(recording: true)
        CaptureSoundPlayer.play(.start)

        let style = settings.overlayAnimationStyle
        if style.showsOverlay {
            AudioLevelMonitor.shared.startMonitoring()
            RecordingOverlayWindowController.shared.show()
        }
    }

    @MainActor
    private func teardownRecordingUI() {
        recordingStart.cancel()
        pttSessionActive = false
        updateMenuBarIcon(recording: false)
        AudioLevelMonitor.shared.stopMonitoring()
        RecordingOverlayWindowController.shared.hide()
    }

    @MainActor
    @objc private func stopRecording() {
        parakeetService.stopRecording()
        CaptureSoundPlayer.play(.stop)
        teardownRecordingUI()
    }

    @MainActor
    @objc private func cancelRecording() {
        let wasPending = recordingRequested && !settings.isRecording
        recordingStart.cancel()
        parakeetService.cancelRecording()
        if wasPending { parakeetService.sessionStatus = "Recording cancelled" }
        CaptureSoundPlayer.play(.stop)
        teardownRecordingUI()
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
        window.setContentSize(NSSize(width: 800, height: 620))
        window.styleMask = [.titled, .closable, .resizable]
        window.title = ""
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 720, height: 540)
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

    func updateMenuBarIcon(recording: Bool) {
        if recording {
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            if let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Superkeet - Recording")?
                .withSymbolConfiguration(config) {
                image.size = NSSize(width: 16, height: 18)
                image.isTemplate = false
                statusItem?.button?.image = image
            }
            statusItem?.button?.contentTintColor = nil
        } else {
            let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Superkeet")
            image?.size = NSSize(width: 18, height: 18)
            statusItem?.button?.image = image
            statusItem?.button?.contentTintColor = nil
        }
    }

    @MainActor
    func toggleRecording() {
        if settings.isRecording {
            stopRecording()
        } else if recordingRequested {
            cancelRecording()
        } else {
            pttSessionActive = false
            startRecording()
        }
    }

    @MainActor
    func startRecordingOnly() {
        guard !settings.isRecording && !recordingRequested else { return }
        pttSessionActive = true
        startRecording()
    }

    @MainActor
    func stopPushToTalk() {
        guard pttSessionActive else { return }
        pttSessionActive = false
        stopRecordingOnly()
    }

    @MainActor
    func stopRecordingOnly() {
        guard settings.isRecording || recordingRequested else { return }
        stopRecording()
    }

    @MainActor
    func cancelRecordingOnly() {
        guard settings.isRecording || recordingRequested else { return }
        cancelRecording()
    }
}
