import Foundation
import AppKit
import Carbon

/// Handles pasting transcribed text into the active application.
/// Uses CGEvent to simulate Cmd+V after placing text on the clipboard.
final class PasteService {
    static let shared = PasteService()

    private init() {}

    /// Routes text to the configured output destinations.
    func deliverText(_ text: String) {
        let settings = AppSettings.shared
        let decision = OutputRouting.decision(
            clipboardCopyEnabled: settings.clipboardCopyEnabled,
            autoPasteEnabled: settings.autoPasteEnabled,
            saveHistoryEnabled: settings.saveHistoryEnabled
        )

        if decision.shouldCopyToClipboard {
            copyToClipboard(text)
        }

        if decision.shouldAutoPaste {
            // Small delay to ensure clipboard is ready and focus returns
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.simulatePaste()
            }
        }
    }

    /// Copy text to system clipboard
    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Simulate Cmd+V keystroke to paste from clipboard
    private func simulatePaste() {
        // Key code 9 = 'v'
        let keyCode: CGKeyCode = 9

        // Create key down event with Cmd modifier
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) else { return }
        keyDown.flags = .maskCommand

        // Create key up event
        guard let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { return }
        keyUp.flags = .maskCommand

        // Post the events
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
