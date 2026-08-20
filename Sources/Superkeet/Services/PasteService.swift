import Foundation
import AppKit
import Carbon

/// Handles pasting transcribed text into the active application.
/// Uses CGEvent to simulate Cmd+V after placing text on the clipboard.
final class PasteService {
    static let shared = PasteService()

    private init() {}

    /// Routes text to the configured output destinations.
    func deliverText(_ text: String, decision: OutputRoutingDecision, targetProcessIdentifier: pid_t? = nil) {
        if decision.shouldAutoPaste {
            guard AXIsProcessTrusted() else {
                copyToClipboard(text)
                DispatchQueue.main.async {
                    AppSettings.shared.runtimeIssue = "Paste Automatically needs Accessibility access. Copied to clipboard instead."
                }
                return
            }

            // Only snapshot the clipboard when we will actually restore it —
            // when "Copy to Clipboard" is enabled the transcript stays, so a
            // full snapshot (which eagerly copies every item's data, including
            // large image payloads) would be wasted work per recording.
            let savedClipboard = decision.shouldKeepClipboardAfterPaste
                ? []
                : snapshotClipboard()
            let transcriptChangeCount = copyToClipboard(text)
            reactivateTargetApplication(processIdentifier: targetProcessIdentifier)

            // Load-bearing timing: the 150ms delay gives the target app time to
            // reactivate before Cmd+V is posted. The 300ms delay lets the paste
            // complete before we restore the original clipboard. If the target
            // app is slow to activate, the paste may land in the wrong focus —
            // there is no synchronous "paste completed" event from CGEvent.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.simulatePaste()
                // Restore original clipboard after paste completes
                // (unless user also wants clipboard copy, in which case keep the transcription)
                if !decision.shouldKeepClipboardAfterPaste {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.restoreClipboard(savedClipboard, ifCurrentChangeCount: transcriptChangeCount)
                    }
                }
            }
        } else if decision.shouldCopyToClipboard {
            copyToClipboard(text)
        }
    }

    /// Bring the app that was active when recording started back to the front so
    /// auto-paste goes where the user initiated dictation, not wherever focus
    /// happened to land while the transcription was finishing.
    private func reactivateTargetApplication(processIdentifier: pid_t?) {
        guard let processIdentifier,
              let app = NSRunningApplication(processIdentifier: processIdentifier),
              !app.isTerminated else {
            return
        }

        app.activate(options: [])
    }

    /// Copy text to system clipboard
    @discardableResult
    func copyToClipboard(_ text: String) -> Int {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return pasteboard.changeCount
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
    private func restoreClipboard(_ items: [[NSPasteboard.PasteboardType: Data]], ifCurrentChangeCount expectedChangeCount: Int) {
        let pb = NSPasteboard.general
        guard pb.changeCount == expectedChangeCount else { return }

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
