import AppKit
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
    private var didFinishOnboarding: Bool = false
    private var isTerminating: Bool = false
    private var shutdownTask: Task<Void, Never>?
    /// Upper bound on quit cleanup. Engine stop is ≤ ~4 s in the worst case (1 s graceful + 2 s
    /// SIGTERM + 1 s SIGKILL), so this leaves headroom before forcing exit.
    private static let shutdownDeadlineSeconds: Double = 6

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        MainMenu.install()

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
        hotkeyManager.onCommandPushToTalkStarted = { [weak self] in
            DispatchQueue.main.async {
                appLog.info("Command PTT start callback fired — starting command recording")
                self?.menuBarManager.startCommandPushToTalk()
            }
        }
        hotkeyManager.onCommandPushToTalkEnded = { [weak self] in
            DispatchQueue.main.async {
                appLog.info("Command PTT end callback fired — stopping command recording")
                self?.menuBarManager.stopPushToTalk()
            }
        }
        hotkeyManager.onEscapePressed = { [weak self] in
            appLog.info("Escape callback fired — cancelling active work")
            ListeningSessionController.shared.end(dispatchPending: false)
            self?.menuBarManager.cancelRecordingOnly()
            AgentSessionController.shared.cancel()
        }
    }

    private func showOnboardingWindow() {
        SetupWindowSession.shared.present(
            onComplete: { [weak self] in
                self?.completeOnboarding()
            },
            onClose: { [weak self] in
                // Closing Setup without finishing counts as "skip": start services anyway so the
                // menu bar app is fully functional. Setup can be re-run from the menu.
                appLog.info("Setup window closed before completion — skipping setup")
                self?.completeOnboarding(closeWindow: false)
            }
        )
    }

    private func completeOnboarding(closeWindow: Bool = true) {
        guard !didFinishOnboarding else { return }
        didFinishOnboarding = true
        settings.hasCompletedOnboarding = true
        if closeWindow {
            SetupWindowSession.shared.close()
        }
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
        // Connect enabled MCP servers now rather than on the first command, so a cold `npx` start
        // is not on the critical path of the first action.
        Task { await MCPClientManager.shared.connectEnabledServersIfNeeded() }
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
            } catch is CancellationError {
                appLog.info("Parakeet daemon start cancelled")
            } catch {
                appLog.error("Failed to start daemon: \(error.localizedDescription)")
                await MainActor.run {
                    // Don't block quit with a modal, and don't report a failure caused by quitting.
                    guard !self.isTerminating else { return }
                    let alert = NSAlert()
                    alert.messageText = "Failed to start Parakeet"
                    let diagnosticMessage = parakeetService.lastUserFacingError ?? error.localizedDescription
                    alert.informativeText = "Could not start the Parakeet speech engine.\n\n\(diagnosticMessage)"
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Open Settings")
                    alert.addButton(withTitle: "Quit")
                    alert.addButton(withTitle: "Continue Without Daemon")

                    // Accessory apps aren't frontmost; without this the alert can open behind other windows.
                    NSApp.activate(ignoringOtherApps: true)
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
            await self?.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }

    private func installSignalHandlers() {
        // A no-op handler (rather than SIG_IGN) keeps the default "terminate" action from firing
        // while still letting the DispatchSources below observe the signal. Unlike SIG_IGN, a
        // caught signal is reset to SIG_DFL on exec, so child processes (speech engine, model
        // download, MCP servers) still respond to SIGTERM/SIGINT.
        installNoOpSignalHandler(SIGINT)
        installNoOpSignalHandler(SIGTERM)

        sigintSource = makeShutdownSignalSource(SIGINT, name: "SIGINT")
        sigtermSource = makeShutdownSignalSource(SIGTERM, name: "SIGTERM")
    }

    private func makeShutdownSignalSource(_ signalNumber: Int32, name: String) -> DispatchSourceSignal {
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
        source.setEventHandler { [weak self] in
            appLog.info("Received \(name, privacy: .public), cleaning up...")
            Task { @MainActor [weak self] in
                self?.isTerminating = true
                await self?.shutdown()
                exit(0)
            }
        }
        source.resume()
        return source
    }

    /// Runs shutdown cleanup once, no matter how many quit paths (menu, SIGINT, SIGTERM) request it.
    private func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        let task = Task { await self.performShutdownCleanupWithDeadline() }
        shutdownTask = task
        await task.value
    }

    /// Races cleanup against a hard deadline so quitting can never hang (e.g. on a stuck model
    /// download or an unresponsive engine). On timeout the engine is SIGKILLed so it isn't orphaned.
    private func performShutdownCleanupWithDeadline() async {
        let gate = ShutdownGate()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task { @MainActor in
                await self.performShutdownCleanup()
                if gate.claim() { continuation.resume() }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(Self.shutdownDeadlineSeconds))
                guard gate.claim() else { return }
                appLog.error("Shutdown cleanup exceeded \(Self.shutdownDeadlineSeconds)s; forcing exit")
                self.parakeetService.forceKillDaemonForExit()
                continuation.resume()
            }
        }
    }

    private func performShutdownCleanup() async {
        // Stop input first so a hotkey press during shutdown can't start a new recording or
        // relaunch the engine after it has been stopped.
        hotkeyManager.stopListening()
        parakeetService.beginShutdown()
        AgentSessionController.shared.cancel()
        HistoryStore.shared.flushPendingSave()
        UsageStatsStore.shared.flushPendingSave()
        async let engineStopped: Void = parakeetService.cleanupAndWait()
        async let mcpDisconnected: Void = MCPClientManager.shared.disconnectAll()
        _ = await (engineStopped, mcpDisconnected)
        AudioLevelMonitor.shared.stopMonitoring()
    }
}

/// One-shot flag used to resume the shutdown continuation exactly once. Main-actor isolated, so
/// no locking is needed.
@MainActor
private final class ShutdownGate {
    private var claimed = false

    func claim() -> Bool {
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

private func installNoOpSignalHandler(_ signalNumber: Int32) {
    var action = sigaction()
    action.__sigaction_u = __sigaction_u(__sa_handler: { _ in })
    action.sa_mask = 0
    action.sa_flags = SA_RESTART
    if sigaction(signalNumber, &action, nil) != 0 {
        appLog.error("Failed to install handler for signal \(signalNumber): errno \(errno)")
    }
}
