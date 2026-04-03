import AppKit
import SwiftUI
import os.log

private let appLog = Logger(subsystem: "com.superkeet.app", category: "AppDelegate")

/// AppDelegate handles the lifecycle, menu bar setup, daemon management, and hotkey registration
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let menuBarManager = MenuBarManager.shared
    private let parakeetService = ParakeetService.shared
    private let hotkeyManager = HotkeyManager.shared
    private let settings = AppSettings.shared
    private var sigintSource: DispatchSourceSignal?
    private var sigtermSource: DispatchSourceSignal?
    private var onboardingWindowController: NSWindowController?
    private var didFinishOnboarding: Bool = false
    private var isTerminating: Bool = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide the dock icon (LSUIElement in Info.plist handles this for release builds,
        // but for swift run we need this)
        NSApp.setActivationPolicy(.accessory)

        // Install signal handlers so cleanup runs even on Ctrl-C / kill
        installSignalHandlers()

        // Setup menu bar
        menuBarManager.setup()

        // Setup hotkeys
        setupHotkeys()

        // Show onboarding or start daemon
        if !settings.hasCompletedOnboarding {
            showOnboardingWindow()
        } else {
            activatePostOnboardingServices()
            startDaemonWithErrorHandling()
        }
    }

    private func setupHotkeys() {
        hotkeyManager.onToggleHotkeyPressed = { [weak self] in
            DispatchQueue.main.async {
                appLog.info("Toggle recording callback fired")
                self?.menuBarManager.toggleRecording()
            }
        }
        hotkeyManager.onPushToTalkStarted = { [weak self] in
            DispatchQueue.main.async {
                appLog.info("PTT start callback fired — starting recording")
                self?.menuBarManager.startRecordingOnly()
            }
        }
        hotkeyManager.onPushToTalkEnded = { [weak self] in
            DispatchQueue.main.async {
                appLog.info("PTT end callback fired — stopping recording")
                self?.menuBarManager.stopRecordingOnly()
            }
        }
        hotkeyManager.onEscapePressed = { [weak self] in
            DispatchQueue.main.async {
                appLog.info("Escape callback fired — cancelling recording")
                self?.menuBarManager.stopRecordingOnly()
            }
        }
    }

    private func showOnboardingWindow() {
        if let existingWindow = onboardingWindowController?.window, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let onboardingView = OnboardingView { [weak self] in
            self?.completeOnboarding()
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
            selector: #selector(onboardingWindowWillClose),
            name: NSWindow.willCloseNotification,
            object: window
        )
    }

    @objc private func onboardingWindowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === onboardingWindowController?.window else { return }
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.onboardingWindowController?.window === window else { return }
            self.onboardingWindowController = nil
        }
    }

    private func completeOnboarding() {
        guard !didFinishOnboarding else { return }
        didFinishOnboarding = true
        settings.hasCompletedOnboarding = true
        onboardingWindowController?.window?.close()
        onboardingWindowController = nil
        NSApp.setActivationPolicy(.accessory)
        activatePostOnboardingServices()
        startDaemonWithErrorHandling()
    }

    private func activatePostOnboardingServices() {
        // Silent check — never prompt after onboarding (permissions may reset after brew upgrade)
        hotkeyManager.accessibilityGranted = hotkeyManager.checkAccessibilitySilently()
        hotkeyManager.startListening()
        if !hotkeyManager.isListening {
            hotkeyManager.startRetryTimer()
        }
    }

    private func startDaemonWithErrorHandling() {
        Task {
            do {
                print("[Superkeet] Starting Parakeet daemon...")
                try await parakeetService.startDaemon()
                print("[Superkeet] Parakeet daemon started successfully")
            } catch {
                print("[Superkeet] Failed to start daemon: \(error)")
                // Show an alert to the user
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Failed to start Parakeet"
                    let diagnosticMessage = parakeetService.lastUserFacingError ?? error.localizedDescription
                    alert.informativeText = "Could not start the Parakeet speech engine.\n\n\(diagnosticMessage)"
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Open Settings")
                    alert.addButton(withTitle: "Quit")
                    alert.addButton(withTitle: "Continue Without Daemon")

                    let response = alert.runModal()
                    switch response {
                    case .alertFirstButtonReturn:
                        MenuBarManager.shared.openSettings()
                    case .alertSecondButtonReturn:
                        NSApp.terminate(nil)
                    default:
                        break
                    }
                }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateNow }
        isTerminating = true

        Task { [weak self] in
            await self?.performShutdownCleanup()
            await MainActor.run {
                sender.reply(toApplicationShouldTerminate: true)
            }
        }

        return .terminateLater
    }

    // MARK: - Signal Handlers

    /// Install SIGINT and SIGTERM handlers so the parakeet daemon gets cleaned up
    /// even when the app is killed via Ctrl-C (swift run) or `kill`.
    private func installSignalHandlers() {
        // Ignore the default signal behavior so our dispatch sources can handle them
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        let sigintSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigintSrc.setEventHandler { [weak self] in
            print("\n[Superkeet] Received SIGINT, cleaning up...")
            Task { @MainActor [weak self] in
                await self?.performShutdownCleanup()
                exit(0)
            }
        }
        sigintSrc.resume()
        self.sigintSource = sigintSrc

        let sigtermSrc = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigtermSrc.setEventHandler { [weak self] in
            print("[Superkeet] Received SIGTERM, cleaning up...")
            Task { @MainActor [weak self] in
                await self?.performShutdownCleanup()
                exit(0)
            }
        }
        sigtermSrc.resume()
        self.sigtermSource = sigtermSrc
    }

    private func performShutdownCleanup() async {
        await parakeetService.cleanupAndWait()
        hotkeyManager.stopListening()
        AudioLevelMonitor.shared.stopMonitoring()
    }
}
