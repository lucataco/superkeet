enum ToggleHotkeyPolicy {
    enum Action { case ignore, toggle, consumeRepeat }

    static func action(isKeyDown: Bool, matchesShortcut: Bool, isRepeat: Bool) -> Action {
        guard isKeyDown, matchesShortcut else { return .ignore }
        return isRepeat ? .consumeRepeat : .toggle
    }
}
