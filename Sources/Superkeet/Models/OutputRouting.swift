import Foundation

struct OutputRoutingDecision: Equatable {
    let shouldCopyToClipboard: Bool
    let shouldAutoPaste: Bool
    let shouldSaveHistory: Bool
    let shouldKeepClipboardAfterPaste: Bool
}

enum OutputRouting {
    /// The clipboard is the floor: every take is copied so text can never be stranded inside the
    /// app. `keepOnClipboardAfterPaste` only matters with auto-paste, where turning it off restores
    /// whatever the user had copied before the paste.
    static func decision(
        keepOnClipboardAfterPaste: Bool,
        autoPasteEnabled: Bool,
        saveHistoryEnabled: Bool
    ) -> OutputRoutingDecision {
        OutputRoutingDecision(
            shouldCopyToClipboard: true,
            shouldAutoPaste: autoPasteEnabled,
            shouldSaveHistory: saveHistoryEnabled,
            shouldKeepClipboardAfterPaste: !autoPasteEnabled || keepOnClipboardAfterPaste
        )
    }
}
