import AppKit
import SwiftUI
import os.log

private let appLog = Logger(subsystem: "com.superkeet.app", category: "AppDelegate")

@MainActor
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
        NSApp.setActivationPolicy(.accessory)

        installSignalHandlers()

        settings.applyAppearancePreference()

        menuBarManager.setup()

        RecordingOverlayWindowController.shared.start()
        ActionHUDWindowController.shared.start()

        setupHotkeys()

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
                self?.menuBarManager.stopPushToTalk()
            }
        }
        hotkeyManager.onCommandHotkeyPressed = { [weak self] in
            DispatchQueue.main.async {
                appLog.info("Command hotkey callback fired")
                self?.menuBarManager.toggleCommandRecording()
            }
        }
        hotkeyManager.onEscapePressed = { [weak self] in
            appLog.info("Escape callback fired — cancelling active work")
            self?.menuBarManager.cancelRecordingOnly()
            AgentSessionController.shared.cancel()
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
        hotkeyManager.accessibilityGranted = hotkeyManager.checkAccessibilitySilently()
        hotkeyManager.startListening()
        if !hotkeyManager.isListening {
            hotkeyManager.startRetryTimer()
        }
        Task { await SpeculativeLaunchCoordinator.shared.prepare() }
        // Build the level-meter audio graph once startup has settled so the first recording's
        // overlay appears without paying for HAL setup on the hot path.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            MicrophoneTapHub.shared.prewarm()
        }
    }

    private func startDaemonWithErrorHandling() {
        Task {
            do {
                appLog.info("Starting Parakeet daemon...")
                try await parakeetService.startDaemon()
                appLog.info("Parakeet daemon started successfully")
            } catch {
                appLog.error("Failed to start daemon: \(error.localizedDescription)")
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

    private func installSignalHandlers() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        let sigintSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigintSrc.setEventHandler { [weak self] in
            appLog.info("Received SIGINT, cleaning up...")
            Task { @MainActor [weak self] in
                await self?.performShutdownCleanup()
                exit(0)
            }
        }
        sigintSrc.resume()
        self.sigintSource = sigintSrc

        let sigtermSrc = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigtermSrc.setEventHandler { [weak self] in
            appLog.info("Received SIGTERM, cleaning up...")
            Task { @MainActor [weak self] in
                await self?.performShutdownCleanup()
                exit(0)
            }
        }
        sigtermSrc.resume()
        self.sigtermSource = sigtermSrc
    }

    private func performShutdownCleanup() async {
        AgentSessionController.shared.cancel()
        HistoryStore.shared.flushPendingSave()
        UsageStatsStore.shared.flushPendingSave()
        await parakeetService.cleanupAndWait()
        hotkeyManager.stopListening()
        AudioLevelMonitor.shared.stopMonitoring()
    }
}
