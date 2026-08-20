import AppKit
import Foundation
import ServiceManagement
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
    @AppStorage("hasVerifiedSetup") var hasVerifiedSetup: Bool = false

    // MARK: - Launch Behavior
    @AppStorage("launchAtLoginEnabled") var launchAtLoginEnabled: Bool = false

    // MARK: - Recording (advanced)
    @AppStorage("audioInputDevice") var audioInputDevice: String = ""  // empty = system default
    @AppStorage("modelDirectory") var modelDirectory: String = ""
    @AppStorage("idleTimeoutMinutes") var idleTimeoutMinutes: Int = 0  // 0 = disabled

    // MARK: - Appearance
    /// Recording overlay style: persisted as a raw `OverlayAnimationStyle` string.
    @AppStorage("recordingOverlayStyle") var recordingOverlayStyle: String = OverlayAnimationStyle.mini.rawValue

    /// Resolved overlay style; unknown legacy values fall back to mini.
    var overlayAnimationStyle: OverlayAnimationStyle {
        OverlayAnimationStyle.resolve(recordingOverlayStyle)
    }

    /// Capture sound cues, persisted as a raw `CaptureSoundStyle` string.
    @AppStorage("captureSoundStyle") var captureSoundStyle: String = CaptureSoundStyle.systemCue.rawValue

    /// Resolved capture-sound style; unknown values fall back to the system cue.
    var captureSoundStyleResolved: CaptureSoundStyle {
        CaptureSoundStyle(rawValue: captureSoundStyle) ?? .systemCue
    }

    /// App-wide theme. Defaults to `.system` to honor the macOS appearance setting.
    @AppStorage("appearancePreference") var appearancePreference: AppearancePreference = .system

    // MARK: - Output
    @AppStorage("autoPasteEnabled") var autoPasteEnabled: Bool = false
    @AppStorage("clipboardCopyEnabled") var clipboardCopyEnabled: Bool = true
    @AppStorage("saveHistoryEnabled") var saveHistoryEnabled: Bool = false
    @AppStorage("fillerWordRemovalEnabled") var fillerWordRemovalEnabled: Bool = false

    // MARK: - State (non-persisted observation)
    @Published var isRecording: Bool = false
    @Published var isDaemonRunning: Bool = false
    @Published var runtimeIssue: String?

    /// Resolved path to the speech engine binary. Public app bundles only use
    /// the embedded engine; local development can use explicit overrides or
    /// well-known host paths.
    var parakeetBinaryPath: String {
        if let bundledPath = bundledBinaryPath {
            return bundledPath
        }
        if isRunningFromAppBundle {
            return missingBundledBinaryPlaceholderPath
        }
        if let resolved = resolvedDevelopmentBinaryPath {
            return resolved
        }
        return missingBundledBinaryPlaceholderPath
    }

    var missingParakeetBinaryMessage: String {
        if isRunningFromAppBundle {
            return "Superkeet could not find the embedded Parakeet engine at \(parakeetBinaryPath). Reinstall the app to restore the bundled engine."
        }

        return "Superkeet could not find or build a local Parakeet engine for swift run. Install git and Rust/Cargo, or build parakeet-cli and set PARAKEET_CLI_PATH=/absolute/path/to/parakeet.\n\nLast checked: \(parakeetBinaryPath)"
    }

    var canBootstrapDevelopmentParakeet: Bool {
        !isRunningFromAppBundle
    }

    var developmentParakeetSourceDirectory: URL {
        Self.developmentParakeetSourceDirectory()
    }

    static func developmentParakeetSourceDirectory(
        currentDirectory: String = FileManager.default.currentDirectoryPath
    ) -> URL {
        URL(fileURLWithPath: currentDirectory)
            .appendingPathComponent(".build/parakeet-cli", isDirectory: true)
    }

    /// Directory the bundled engine reads model files from.
    ///
    /// When `modelDirectory` is set (Advanced settings), it wins. Otherwise we
    /// use the same default `parakeet-cli` computes for itself, and always pass
    /// it explicitly to both `download` and `serve` so the two never drift.
    var effectiveModelDirectory: String {
        if !modelDirectory.isEmpty {
            return modelDirectory
        }
        return Self.defaultModelDirectory.path
    }

    /// Default on-device model location, matching `parakeet-cli`'s
    /// `~/Library/Application Support/parakeet/models/parakeet-tdt-0.6b-v3`.
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

    /// Applies the saved appearance preference to the running app. Safe to call
    /// from any thread; the actual `NSApp` mutation is forced onto the main queue.
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

    // MARK: - Binary Discovery

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

    /// Searches for the development parakeet binary in well-known local paths.
    private var resolvedDevelopmentBinaryPath: String? {
        Self.resolveDevelopmentBinaryPath()
    }

    static func resolveDevelopmentBinaryPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory(),
        currentDirectory: String = FileManager.default.currentDirectoryPath,
        systemSearchPaths: [String] = [
            "/opt/homebrew/bin/parakeet",
            "/usr/local/bin/parakeet"
        ],
        fileManager: FileManager = .default
    ) -> String? {
        var candidates: [String] = []
        let home = homeDirectory

        for key in ["PARAKEET_BINARY_PATH", "PARAKEET_CLI_PATH"] {
            if let path = environment[key], !path.isEmpty {
                candidates.append(path)
            }
        }

        if let sourceDirectory = environment["PARAKEET_SOURCE_DIR"], !sourceDirectory.isEmpty {
            candidates.append("\(sourceDirectory)/target/release/parakeet")
            candidates.append("\(sourceDirectory)/target/debug/parakeet")
        }

        candidates.append(contentsOf: [
            "\(currentDirectory)/.build/parakeet-cli/target/release/parakeet",
            "\(currentDirectory)/.build/parakeet-cli/target/debug/parakeet",
            "\(currentDirectory)/../parakeet-cli/target/release/parakeet",
            "\(currentDirectory)/../parakeet-cli/target/debug/parakeet",
            "\(home)/Code/CLIs/parakeet-cli/target/release/parakeet",
            "\(home)/Code/CLIs/parakeet-cli/target/debug/parakeet",
            "\(home)/.cargo/bin/parakeet",
        ] + systemSearchPaths)

        candidates.append(contentsOf: pathCandidates(environment: environment))

        return candidates
            .map { expandTilde($0, homeDirectory: homeDirectory) }
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            .first { fileManager.isExecutableFile(atPath: $0) }
    }

    private static func pathCandidates(environment: [String: String]) -> [String] {
        guard let path = environment["PATH"], !path.isEmpty else { return [] }
        return path.split(separator: ":").map { "\($0)/parakeet" }
    }

    private static func expandTilde(_ path: String, homeDirectory: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return homeDirectory + path.dropFirst().description
    }
}
