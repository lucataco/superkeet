import Foundation
import SwiftUI

/// Persisted app settings backed by UserDefaults
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // MARK: - Toggle Recording Hotkey (press to start, press again to stop)
    @AppStorage("toggleHotkeyKeyCode") var toggleHotkeyKeyCode: Int = 49  // Space
    @AppStorage("toggleHotkeyModifierFlags") var toggleHotkeyModifierFlags: Int = 524288  // maskAlternate
    @AppStorage("toggleHotkeyDisplayName") var toggleHotkeyDisplayName: String = "⌥ Space"

    // MARK: - Push to Talk Hotkey (hold to record, release to stop)
    @AppStorage("pttHotkeyKeyCode") var pttHotkeyKeyCode: Int = 63  // fn key
    @AppStorage("pttHotkeyModifierFlags") var pttHotkeyModifierFlags: Int = 0
    @AppStorage("pttHotkeyDisplayName") var pttHotkeyDisplayName: String = "fn"

    // MARK: - Recording
    @AppStorage("audioInputDevice") var audioInputDevice: String = ""  // empty = system default
    @AppStorage("vadThreshold") var vadThreshold: Double = 0.5
    @AppStorage("silenceTimeoutMs") var silenceTimeoutMs: Int = 1500
    @AppStorage("modelDirectory") var modelDirectory: String = ""

    // MARK: - Appearance
    /// Recording overlay style: "classic" (expanded bars), "mini" (compact dots), "none" (hidden)
    @AppStorage("recordingOverlayStyle") var recordingOverlayStyle: String = "mini"

    // MARK: - Output
    @AppStorage("autoPasteEnabled") var autoPasteEnabled: Bool = true
    @AppStorage("clipboardCopyEnabled") var clipboardCopyEnabled: Bool = true

    // MARK: - Paths
    @AppStorage("parakeetCliPath") var parakeetCliPath: String = "/Users/lucataco/Code/CLIs/parakeet-cli"

    // MARK: - State (non-persisted observation)
    @Published var isRecording: Bool = false
    @Published var isDaemonRunning: Bool = false

    var parakeetBinaryPath: String {
        "\(parakeetCliPath)/target/release/parakeet-cli"
    }

    var socketPath: String {
        "/tmp/parakeet.sock"
    }

    var pidFilePath: String {
        "/tmp/parakeet.pid"
    }

    private init() {}
}
