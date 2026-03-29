import Foundation
import SwiftUI

/// Persisted app settings backed by UserDefaults
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // MARK: - Primary Shortcut (press to start, press again to stop)
    @AppStorage("toggleHotkeyKeyCode") var toggleHotkeyKeyCode: Int = 49  // Space
    @AppStorage("toggleHotkeyModifierFlags") var toggleHotkeyModifierFlags: Int = 524288  // maskAlternate
    @AppStorage("toggleHotkeyDisplayName") var toggleHotkeyDisplayName: String = "⌥ Space"

    // MARK: - Advanced Push to Talk Shortcut (hold to record, release to stop)
    @AppStorage("pttHotkeyKeyCode") var pttHotkeyKeyCode: Int = 63  // fn key
    @AppStorage("pttHotkeyModifierFlags") var pttHotkeyModifierFlags: Int = 0
    @AppStorage("pttHotkeyDisplayName") var pttHotkeyDisplayName: String = "fn"

    // MARK: - First Run
    @AppStorage("hasCompletedOnboarding") var hasCompletedOnboarding: Bool = false

    // MARK: - Launch Behavior
    @AppStorage("launchAtLoginEnabled") var launchAtLoginEnabled: Bool = false

    // MARK: - Recording (advanced)
    @AppStorage("audioInputDevice") var audioInputDevice: String = ""  // empty = system default
    @AppStorage("modelDirectory") var modelDirectory: String = ""
    @AppStorage("idleTimeoutMinutes") var idleTimeoutMinutes: Int = 0  // 0 = disabled

    // MARK: - Appearance
    /// Recording overlay style: "classic" (expanded bars), "mini" (compact dots), "none" (hidden)
    @AppStorage("recordingOverlayStyle") var recordingOverlayStyle: String = "mini"

    // MARK: - Output
    @AppStorage("autoPasteEnabled") var autoPasteEnabled: Bool = false
    @AppStorage("clipboardCopyEnabled") var clipboardCopyEnabled: Bool = true
    @AppStorage("saveHistoryEnabled") var saveHistoryEnabled: Bool = false
    @AppStorage("fillerWordRemovalEnabled") var fillerWordRemovalEnabled: Bool = false

    // MARK: - State (non-persisted observation)
    @Published var isRecording: Bool = false
    @Published var isDaemonRunning: Bool = false
    @Published var runtimeIssue: String?

    /// Resolved path to the bundled speech engine binary.
    /// Public app bundles only use the embedded engine. Local development
    /// can still fall back to well-known host paths.
    var parakeetBinaryPath: String {
        if let bundledPath = bundledBinaryPath {
            return bundledPath
        }
        if let resolved = resolvedDevelopmentBinaryPath {
            return resolved
        }
        return "\(NSHomeDirectory())/Code/CLIs/parakeet-cli/target/release/parakeet"
    }

    var hasBundledParakeetBinary: Bool {
        bundledBinaryPath != nil
    }

    var socketPath: String {
        AppReadiness.runtimeFilesDirectory().appendingPathComponent("parakeet.sock").path
    }

    var pidFilePath: String {
        AppReadiness.runtimeFilesDirectory().appendingPathComponent("parakeet.pid").path
    }

    private init() {}

    // MARK: - Binary Discovery

    private var bundledBinaryPath: String? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("bin/parakeet").path,
            Bundle.main.resourceURL?.appendingPathComponent("parakeet").path,
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("parakeet").path
        ]

        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Searches for the development parakeet binary in well-known local paths.
    private var resolvedDevelopmentBinaryPath: String? {
        let fm = FileManager.default
        let home = NSHomeDirectory()

        let candidates = [
            "\(home)/Code/CLIs/parakeet-cli/target/release/parakeet",
            "\(home)/.cargo/bin/parakeet",
            "/usr/local/bin/parakeet",
            "/opt/homebrew/bin/parakeet"
        ]

        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }
}
