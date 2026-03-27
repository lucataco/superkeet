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

    // MARK: - Recording (advanced)
    @AppStorage("audioInputDevice") var audioInputDevice: String = ""  // empty = system default
    @AppStorage("vadThreshold") var vadThreshold: Double = 0.5
    @AppStorage("silenceTimeoutMs") var silenceTimeoutMs: Int = 1500
    @AppStorage("modelDirectory") var modelDirectory: String = ""

    // MARK: - Appearance
    /// Recording overlay style: "classic" (expanded bars), "mini" (compact dots), "none" (hidden)
    @AppStorage("recordingOverlayStyle") var recordingOverlayStyle: String = "mini"

    // MARK: - Output
    @AppStorage("autoPasteEnabled") var autoPasteEnabled: Bool = false
    @AppStorage("clipboardCopyEnabled") var clipboardCopyEnabled: Bool = true
    @AppStorage("saveHistoryEnabled") var saveHistoryEnabled: Bool = true

    // MARK: - Paths / Engine
    @AppStorage("parakeetCliPath") var parakeetCliPath: String = "/Users/lucataco/Code/CLIs/parakeet-cli"

    // MARK: - State (non-persisted observation)
    @Published var isRecording: Bool = false
    @Published var isDaemonRunning: Bool = false
    @Published var runtimeIssue: String?

    var parakeetBinaryPath: String {
        "\(parakeetCliPath)/target/release/parakeet-cli"
    }

    var socketPath: String {
        AppReadiness.runtimeFilesDirectory().appendingPathComponent("parakeet.sock").path
    }

    var pidFilePath: String {
        AppReadiness.runtimeFilesDirectory().appendingPathComponent("parakeet.pid").path
    }

    private init() {}
}
