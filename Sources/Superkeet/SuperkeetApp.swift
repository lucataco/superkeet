import SwiftUI
import AppKit

/// Superkeet - Voice-to-text Mac app powered by Parakeet
/// Runs as a menu bar app (no dock icon) with global hotkey support
@main
struct SuperkeetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // We use a minimal Settings scene to satisfy SwiftUI's Scene requirement,
        // but the actual UI is driven by NSMenu and NSWindow via AppDelegate
        Settings {
            EmptyView()
        }
    }
}

/// AppDelegate handles the lifecycle, menu bar setup, daemon management, and hotkey registration
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let menuBarManager = MenuBarManager()
    private let parakeetService = ParakeetService.shared
    private let hotkeyManager = HotkeyManager.shared
    private let settings = AppSettings.shared
    private var sigintSource: DispatchSourceSignal?
    private var sigtermSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide the dock icon (LSUIElement in Info.plist handles this for release builds,
        // but for swift run we need this)
        NSApp.setActivationPolicy(.accessory)

        // Install signal handlers so cleanup runs even on Ctrl-C / kill
        installSignalHandlers()

        // Setup menu bar
        menuBarManager.setup()

        // Setup hotkeys
        hotkeyManager.onToggleHotkeyPressed = { [weak self] in
            DispatchQueue.main.async {
                self?.menuBarManager.toggleRecording()
            }
        }
        hotkeyManager.onPushToTalkStarted = { [weak self] in
            DispatchQueue.main.async {
                self?.menuBarManager.startRecordingOnly()
            }
        }
        hotkeyManager.onPushToTalkEnded = { [weak self] in
            DispatchQueue.main.async {
                self?.menuBarManager.stopRecordingOnly()
            }
        }
        hotkeyManager.onEscapePressed = { [weak self] in
            DispatchQueue.main.async {
                self?.menuBarManager.stopRecordingOnly()
            }
        }
        hotkeyManager.startListening()

        // Start the parakeet daemon in the background
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
                        // Open settings - will be handled by user clicking Settings in menu
                        break
                    case .alertSecondButtonReturn:
                        NSApp.terminate(nil)
                    default:
                        break
                    }
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        parakeetService.cleanup()
        hotkeyManager.stopListening()
        AudioLevelMonitor.shared.stopMonitoring()
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
            self?.parakeetService.cleanup()
            self?.hotkeyManager.stopListening()
            AudioLevelMonitor.shared.stopMonitoring()
            exit(0)
        }
        sigintSrc.resume()
        self.sigintSource = sigintSrc

        let sigtermSrc = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigtermSrc.setEventHandler { [weak self] in
            print("[Superkeet] Received SIGTERM, cleaning up...")
            self?.parakeetService.cleanup()
            self?.hotkeyManager.stopListening()
            AudioLevelMonitor.shared.stopMonitoring()
            exit(0)
        }
        sigtermSrc.resume()
        self.sigtermSource = sigtermSrc
    }
}
