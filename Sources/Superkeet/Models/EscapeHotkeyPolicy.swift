enum EscapeHotkeyPolicy {
    enum Action: Equatable {
        case ignore
        case cancelAndPassThrough
        case cancelAndConsume
    }

    static func action(
        isKeyDown: Bool, matchesEscape: Bool, isRepeat: Bool,
        isRecording: Bool, actionSessionActive: Bool
    ) -> Action {
        guard isKeyDown, matchesEscape, !isRepeat else { return .ignore }
        // The action HUD is nonactivating: Escape still belongs to the focused
        // app. Keep the existing recording-only shortcut behavior.
        if actionSessionActive { return .cancelAndPassThrough }
        return isRecording ? .cancelAndConsume : .ignore
    }
}
