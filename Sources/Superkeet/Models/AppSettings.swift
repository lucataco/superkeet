import AppKit
import Foundation
import ServiceManagement
import SwiftUI

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("toggleHotkeyKeyCode") var toggleHotkeyKeyCode: Int = 49
    @AppStorage("toggleHotkeyModifierFlags") var toggleHotkeyModifierFlags: Int = 524288
    @AppStorage("toggleHotkeyDisplayName") var toggleHotkeyDisplayName: String = "⌥ Space"

    @AppStorage("pttHotkeyKeyCode") var pttHotkeyKeyCode: Int = 63
    @AppStorage("pttHotkeyModifierFlags") var pttHotkeyModifierFlags: Int = 0
    @AppStorage("pttHotkeyDisplayName") var pttHotkeyDisplayName: String = "fn"

    @AppStorage("hasCompletedOnboarding") var hasCompletedOnboarding: Bool = false
    @AppStorage("hasVerifiedSetup") var hasVerifiedSetup: Bool = false

    @AppStorage("launchAtLoginEnabled") var launchAtLoginEnabled: Bool = false

    @AppStorage("audioInputDevice") var audioInputDevice: String = ""
    @AppStorage("modelDirectory") var modelDirectory: String = ""
    @AppStorage("idleTimeoutMinutes") var idleTimeoutMinutes: Int = 0

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
    @AppStorage("clipboardCopyEnabled") var clipboardCopyEnabled: Bool = true
    @AppStorage("saveHistoryEnabled") var saveHistoryEnabled: Bool = false
    @AppStorage("fillerWordRemovalEnabled") var fillerWordRemovalEnabled: Bool = false
    @AppStorage("spokenCorrectionsEnabled") var spokenCorrectionsEnabled: Bool = false

    @Published var isRecording: Bool = false
    @Published var isDaemonRunning: Bool = false
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

    private init() {}

    func syncLaunchAtLoginStatus() {
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    func applyAppearancePreference() {
        let appearance = appearancePreference.nsAppearance
        if Thread.isMainThread {
            NSApp.appearance = appearance
        } else {
            DispatchQueue.main.async {
                NSApp.appearance = appearance
            }
        }
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
