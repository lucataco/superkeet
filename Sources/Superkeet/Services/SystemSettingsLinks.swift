import AppKit
import Foundation

enum SystemSettingsLinks {
    private static let privacyPane = "x-apple.systempreferences:com.apple.preference.security"

    static func openMicrophone() {
        open("\(privacyPane)?Privacy_Microphone")
    }

    static func openAccessibility() {
        open("\(privacyPane)?Privacy_Accessibility")
    }

    private static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}
