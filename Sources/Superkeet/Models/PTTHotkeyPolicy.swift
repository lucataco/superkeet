enum PTTKeyAction: Equatable {
    case ignore
    case start
    case consumeRepeat
    case stop
}

enum PTTHotkeyPolicy {
    static func keyAction(isKeyDown: Bool, pttAlreadyDown: Bool, modifiersMatch: Bool) -> PTTKeyAction {
        if isKeyDown {
            if pttAlreadyDown { return .consumeRepeat }
            return modifiersMatch ? .start : .ignore
        }
        return pttAlreadyDown ? .stop : .ignore
    }
}
