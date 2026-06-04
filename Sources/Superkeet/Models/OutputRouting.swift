import Foundation

struct OutputRoutingDecision: Equatable {
    let shouldCopyToClipboard: Bool
    let shouldAutoPaste: Bool
    let shouldSaveHistory: Bool
    let shouldKeepClipboardAfterPaste: Bool
}

enum OutputRouting {
    static func decision(
        clipboardCopyEnabled: Bool,
        autoPasteEnabled: Bool,
        saveHistoryEnabled: Bool
    ) -> OutputRoutingDecision {
        OutputRoutingDecision(
            shouldCopyToClipboard: clipboardCopyEnabled || autoPasteEnabled,
            shouldAutoPaste: autoPasteEnabled,
            shouldSaveHistory: saveHistoryEnabled,
            shouldKeepClipboardAfterPaste: clipboardCopyEnabled
        )
    }
}
