import AppKit
import Foundation
import ServiceManagement
import SwiftUI

final class AppSettings: ObservableObject, @unchecked Sendable {
    static let shared = AppSettings()

    @AppStorage("toggleHotkeyKeyCode") var toggleHotkeyKeyCode: Int = 49
    @AppStorage("toggleHotkeyModifierFlags") var toggleHotkeyModifierFlags: Int = 524288

    @AppStorage("pttHotkeyKeyCode") var pttHotkeyKeyCode: Int = 63
    @AppStorage("pttHotkeyModifierFlags") var pttHotkeyModifierFlags: Int = 0

    @AppStorage("commandHotkeyKeyCode") var commandHotkeyKeyCode: Int = 49
    @AppStorage("commandHotkeyModifierFlags") var commandHotkeyModifierFlags: Int = 655360

    /// Hold-to-talk for Actions Mode; ⌃⇧Space by default (control 0x40000 + shift 0x20000).
    @AppStorage("commandPTTHotkeyKeyCode") var commandPTTHotkeyKeyCode: Int = 49
    @AppStorage("commandPTTHotkeyModifierFlags") var commandPTTHotkeyModifierFlags: Int = 393216

    // Display names are derived from the key code and modifiers so they can never drift.
    var toggleHotkeyDisplayName: String {
        displayNameForHotkey(keyCode: toggleHotkeyKeyCode, modifierFlags: toggleHotkeyModifierFlags)
    }

    var pttHotkeyDisplayName: String {
        displayNameForHotkey(keyCode: pttHotkeyKeyCode, modifierFlags: pttHotkeyModifierFlags)
    }

    var commandHotkeyDisplayName: String {
        displayNameForHotkey(keyCode: commandHotkeyKeyCode, modifierFlags: commandHotkeyModifierFlags)
    }

    var commandPTTHotkeyDisplayName: String {
        displayNameForHotkey(keyCode: commandPTTHotkeyKeyCode, modifierFlags: commandPTTHotkeyModifierFlags)
    }

    @AppStorage("hasCompletedOnboarding") var hasCompletedOnboarding: Bool = false
    @AppStorage("hasVerifiedSetup") var hasVerifiedSetup: Bool = false

    /// Read straight from the system so it can never disagree with what login items actually do.
    var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @AppStorage("audioInputDevice") var audioInputDevice: String = ""
    @AppStorage("modelDirectory") var modelDirectory: String = ""
    @AppStorage("idleTimeoutMinutes") var idleTimeoutMinutes: Int = IdleEnginePolicy.defaultTimeoutMinutes

    @AppStorage("recordingOverlayStyle") var recordingOverlayStyle: String = OverlayAnimationStyle.mini.rawValue

    var overlayAnimationStyle: OverlayAnimationStyle {
        OverlayAnimationStyle.resolve(recordingOverlayStyle)
    }

    @AppStorage("captureSoundStyle") var captureSoundStyle: String = CaptureSoundStyle.systemCue.rawValue

    var captureSoundStyleResolved: CaptureSoundStyle {
        CaptureSoundStyle(rawValue: captureSoundStyle) ?? .systemCue
    }

    @AppStorage("appearancePreference") var appearancePreference: AppearancePreference = .system

    @AppStorage("autoPasteEnabled") var autoPasteEnabled: Bool = false
    /// With auto-paste on, leave the transcript on the clipboard after pasting (off restores the
    /// previous clipboard). Every take is copied regardless; see `OutputRouting`.
    @AppStorage("clipboardCopyEnabled") var clipboardCopyEnabled: Bool = true
    @AppStorage("saveHistoryEnabled") var saveHistoryEnabled: Bool = false
    @AppStorage("fillerWordRemovalEnabled") var fillerWordRemovalEnabled: Bool = false
    @AppStorage("spokenCorrectionsEnabled") var spokenCorrectionsEnabled: Bool = false

    @AppStorage("actionsEnabled") var actionsEnabled: Bool = false
    @AppStorage("actionApprovalPolicy") var actionApprovalPolicy: ActionApprovalPolicy = .readOnlyAuto
    /// The asking policy that was active before the menu bar checkbox switched on auto-approve.
    @AppStorage("actionApprovalPolicyBeforeAutoApprove") var actionApprovalPolicyBeforeAutoApprove: ActionApprovalPolicy?
    @AppStorage("actionMaxSteps") var actionMaxSteps: Int = 12
    @AppStorage("actionTimeoutSeconds") var actionTimeoutSeconds: Int = 120
    @AppStorage("actionRunDeadlineSeconds") var actionRunDeadlineSeconds: Int = 180
    @AppStorage("actionAuditEnabled") var actionAuditEnabled: Bool = true
    @AppStorage("instantAppLaunchEnabled") var instantAppLaunchEnabled: Bool = true
    /// The Actions shortcut opens a listening session (speak several commands, each dispatched on
    /// a pause) instead of one press-to-start, press-to-run take. Off restores the single take.
    @AppStorage("actionListeningSessionEnabled") var actionListeningSessionEnabled: Bool = true

    @Published var isRecording: Bool = false
    @Published var isDaemonRunning: Bool = false
    @Published var isActionSessionActive: Bool = false
    @Published var actionStatusText: String = ""
    @Published var runtimeIssue: String?

    var parakeetBinaryPath: String {
        if let bundledPath = bundledBinaryPath {
            return bundledPath
        }
        if isRunningFromAppBundle {
            return missingBundledBinaryPlaceholderPath
        }
        if let selection = try? DevelopmentEngineLocator.select() {
            return selection.binaryURL.path
        }
        return missingBundledBinaryPlaceholderPath
    }

    var missingParakeetBinaryMessage: String {
        if isRunningFromAppBundle {
            return "Superkeet could not find the embedded Parakeet engine at \(parakeetBinaryPath). Reinstall the app to restore the bundled engine."
        }

        do {
            _ = try DevelopmentEngineLocator.select()
        } catch {
            return error.localizedDescription
        }

        return "Superkeet could not find or build a local Parakeet engine for swift run. Install git and Rust/Cargo, or build parakeet-cli and set PARAKEET_CLI_PATH=/absolute/path/to/parakeet.\n\nLast checked: \(parakeetBinaryPath)"
    }

    var canBootstrapDevelopmentParakeet: Bool {
        !isRunningFromAppBundle
    }

    var effectiveModelDirectory: String {
        if !modelDirectory.isEmpty {
            return modelDirectory
        }
        return Self.defaultModelDirectory.path
    }

    static var defaultModelDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("parakeet/models/parakeet-tdt-0.6b-v3", isDirectory: true)
    }

    var socketPath: String {
        AppReadiness.runtimeFilesDirectory().appendingPathComponent("parakeet.sock").path
    }

    var pidFilePath: String {
        AppReadiness.runtimeFilesDirectory().appendingPathComponent("parakeet.pid").path
    }

    private init() {
        if Bundle.main.bundleIdentifier == "com.superkeet.app" {
            IdleEnginePolicy.applyUpgrade(defaults: .standard)
            idleTimeoutMinutes = UserDefaults.standard.integer(forKey: IdleEnginePolicy.timeoutDefaultsKey)
        }
    }

    @MainActor
    func applyAppearancePreference() {
        NSApp.appearance = appearancePreference.nsAppearance
    }

    private var isRunningFromAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    private var missingBundledBinaryPlaceholderPath: String {
        Bundle.main.resourceURL?.appendingPathComponent("bin/parakeet").path
            ?? "/nonexistent/parakeet"
    }

    private var bundledBinaryPath: String? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("bin/parakeet").path,
            Bundle.main.resourceURL?.appendingPathComponent("parakeet").path,
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("parakeet").path
        ]

        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

}
