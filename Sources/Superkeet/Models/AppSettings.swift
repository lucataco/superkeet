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
    @AppStorage("saveHistoryEnabled") var saveHistoryEnabled: Bool = true
    @AppStorage("fillerWordRemovalEnabled") var fillerWordRemovalEnabled: Bool = false

    // MARK: - Paths / Engine
    /// Optional manual override for the parakeet-cli project directory.
    /// When empty (default), the binary is discovered automatically.
    @AppStorage("parakeetCliPath") var parakeetCliPath: String = ""

    // MARK: - State (non-persisted observation)
    @Published var isRecording: Bool = false
    @Published var isDaemonRunning: Bool = false
    @Published var runtimeIssue: String?

    /// Resolved path to the parakeet-cli binary.
    /// Uses the first location where the binary actually exists on disk,
    /// falling back to the user-configured path if nothing is found.
    var parakeetBinaryPath: String {
        if let resolved = resolvedBinaryPath {
            return resolved
        }
        // Fallback: construct from user-configured path (may not exist)
        if !parakeetCliPath.isEmpty {
            return "\(parakeetCliPath)/target/release/parakeet-cli"
        }
        return "\(NSHomeDirectory())/Code/CLIs/parakeet-cli/target/release/parakeet-cli"
    }

    /// The parakeet-cli project directory for cargo build.
    /// Derived from resolvedBinaryPath, user config, or the default dev location.
    var parakeetProjectDirectory: String {
        // If we found a binary under a target/release path, derive the project root
        if let resolved = resolvedBinaryPath, resolved.hasSuffix("/target/release/parakeet-cli") {
            return String(resolved.dropLast("/target/release/parakeet-cli".count))
        }
        if !parakeetCliPath.isEmpty {
            return parakeetCliPath
        }
        return "\(NSHomeDirectory())/Code/CLIs/parakeet-cli"
    }

    var socketPath: String {
        AppReadiness.runtimeFilesDirectory().appendingPathComponent("parakeet.sock").path
    }

    var pidFilePath: String {
        AppReadiness.runtimeFilesDirectory().appendingPathComponent("parakeet.pid").path
    }

    private init() {
        // Clear stale persisted path if it points to a non-existent binary
        if !parakeetCliPath.isEmpty,
           !FileManager.default.fileExists(atPath: "\(parakeetCliPath)/target/release/parakeet-cli") {
            parakeetCliPath = ""
        }
    }

    // MARK: - Binary Discovery

    /// Searches for the parakeet-cli binary in multiple well-known locations.
    /// Returns the first path where the binary actually exists on disk, or nil.
    private var resolvedBinaryPath: String? {
        let fm = FileManager.default
        let home = NSHomeDirectory()

        var candidates: [String] = []

        // 1. User-configured path takes priority
        if !parakeetCliPath.isEmpty {
            candidates.append("\(parakeetCliPath)/target/release/parakeet-cli")
        }

        // 2. Common dev location relative to $HOME
        candidates.append("\(home)/Code/CLIs/parakeet-cli/target/release/parakeet-cli")

        // 3. App bundle (for future bundled distribution)
        if let bundleBin = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("parakeet-cli").path {
            candidates.append(bundleBin)
        }
        if let resourceBin = Bundle.main.resourceURL?
            .appendingPathComponent("parakeet-cli").path {
            candidates.append(resourceBin)
        }

        // 4. Cargo install location
        candidates.append("\(home)/.cargo/bin/parakeet-cli")

        // 5. Common system paths
        candidates.append("/usr/local/bin/parakeet-cli")
        candidates.append("/opt/homebrew/bin/parakeet-cli")

        return candidates.first { fm.fileExists(atPath: $0) }
    }
}
