import Foundation
import AppKit
import Carbon

final class PasteService: @unchecked Sendable {
    static let shared = PasteService()

    struct Environment {
        var accessibilityTrusted: () -> Bool = { AXIsProcessTrusted() }
        var activateTarget: (pid_t) -> Bool = { pid in
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return false }
            return app.activate(options: [])
        }
        var targetIsFrontmost: (pid_t) -> Bool = { pid in
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return false }
            return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        }
        var sendPaste: () -> Bool = { PasteService.simulatePaste() }
        var schedule: (TimeInterval, @escaping @Sendable () -> Void) -> Void = { delay, action in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        }
        var reportIssue: (String) -> Void = { AppSettings.shared.runtimeIssue = $0 }
    }

    private let pasteboard: NSPasteboard
    private let environment: Environment

    init(pasteboard: NSPasteboard = .general, environment: Environment = Environment()) {
        self.pasteboard = pasteboard
        self.environment = environment
    }

    func deliverText(_ text: String, decision: OutputRoutingDecision, targetProcessIdentifier: pid_t? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        if decision.shouldAutoPaste {
            guard environment.accessibilityTrusted() else {
                copyToClipboard(text)
                environment.reportIssue("Paste Automatically needs Accessibility access. Copied to clipboard instead.")
                return
            }

            let savedClipboard = decision.shouldKeepClipboardAfterPaste
                ? []
                : snapshotClipboard()
            let transcriptChangeCount = copyToClipboard(text)
            guard let targetProcessIdentifier, environment.activateTarget(targetProcessIdentifier) else {
                environment.reportIssue("Automatic paste was cancelled because the original app could not be activated. Use Copy Last Transcript to recover the text.")
                return
            }

            environment.schedule(0.15) {
                guard self.pasteboard.changeCount == transcriptChangeCount else {
                    self.environment.reportIssue("Automatic paste was cancelled because the clipboard changed. Your new clipboard was preserved; use Copy Last Transcript to recover the text.")
                    return
                }
                guard self.environment.accessibilityTrusted(),
                      self.environment.targetIsFrontmost(targetProcessIdentifier) else {
                    self.environment.reportIssue("Automatic paste was cancelled because the original app is no longer ready for paste. Use Copy Last Transcript to recover the text.")
                    return
                }
                guard self.environment.sendPaste() else {
                    self.environment.reportIssue("Automatic paste could not send the paste command. Use Copy Last Transcript to recover the text.")
                    return
                }
                if !decision.shouldKeepClipboardAfterPaste {
                    self.environment.schedule(0.3) {
                        self.restoreClipboard(savedClipboard, ifCurrentChangeCount: transcriptChangeCount)
                    }
                }
            }
        } else if decision.shouldCopyToClipboard {
            copyToClipboard(text)
        }
    }

    @discardableResult
    func copyToClipboard(_ text: String) -> Int {
        dispatchPrecondition(condition: .onQueue(.main))
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return pasteboard.changeCount
    }

    private func snapshotClipboard() -> [[NSPasteboard.PasteboardType: Data]] {
        let pb = pasteboard
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

    private func restoreClipboard(_ items: [[NSPasteboard.PasteboardType: Data]], ifCurrentChangeCount expectedChangeCount: Int) {
        let pb = pasteboard
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

    private static func simulatePaste() -> Bool {
        let keyCode: CGKeyCode = 9

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) else { return false }
        keyDown.flags = .maskCommand

        guard let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { return false }
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
