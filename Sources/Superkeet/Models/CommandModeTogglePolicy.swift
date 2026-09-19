enum CommandModeTogglePolicy {
    enum Action: Equatable {
        case start
        case stop
        case ignore
    }

    static func action(
        actionsEnabled: Bool,
        isRecording: Bool,
        recordingRequested: Bool
    ) -> Action {
        guard actionsEnabled else { return .ignore }
        if isRecording || recordingRequested { return .stop }
        return .start
    }
}
