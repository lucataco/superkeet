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

        if decision.shouldAutoPaste {
            // Save current clipboard, set transcription, paste, then restore original clipboard
            let savedClipboard = snapshotClipboard()
            copyToClipboard(text)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.simulatePaste()
                // Restore original clipboard after paste completes
                // (unless user also wants clipboard copy, in which case keep the transcription)
                if !decision.shouldCopyToClipboard {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.restoreClipboard(savedClipboard)
                    }
                }
            }
        } else if decision.shouldCopyToClipboard {
            copyToClipboard(text)
        }
    }

    /// Copy text to system clipboard
    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - Clipboard Snapshot & Restore

    /// Save all current clipboard contents so they can be restored after a paste operation.
    private func snapshotClipboard() -> [[NSPasteboard.PasteboardType: Data]] {
        let pb = NSPasteboard.general
        return (pb.pasteboardItems ?? []).map { item in
            var snapshot: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    snapshot[type] = data
                }
            }
            return snapshot
        }
    }

    /// Restore previously saved clipboard contents.
    private func restoreClipboard(_ items: [[NSPasteboard.PasteboardType: Data]]) {
        let pb = NSPasteboard.general
        pb.clearContents()

        guard !items.isEmpty else { return }

        let restoredItems = items.compactMap { snapshot -> NSPasteboardItem? in
            let item = NSPasteboardItem()
            for (type, data) in snapshot {
                guard item.setData(data, forType: type) else {
                    return nil
                }
            }
            return item
        }

        if !restoredItems.isEmpty {
            pb.writeObjects(restoredItems)
        }
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
