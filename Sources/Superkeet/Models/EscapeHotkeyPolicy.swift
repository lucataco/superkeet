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
        if actionSessionActive { return .cancelAndPassThrough }
        return isRecording ? .cancelAndConsume : .ignore
    }
}
