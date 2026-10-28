enum SetupSummary: Equatable {
    case ready
    case downloadingModel(percent: Int?)
    case needsAccessibility(autoPaste: Bool)
    case needsAttention([AppReadinessIssue])

    static func make(report: AppReadinessReport, model: ModelProvisionState, autoPasteEnabled: Bool) -> SetupSummary {
        let issues = report.issues
        let hasModelIssue = issues.contains(.model)
        let hasBlockingIssue = issues.contains { $0 != .model && $0 != .accessibility }

        if hasBlockingIssue || (hasModelIssue && !model.isBusy) {
            let shown = issues.filter { issue in
                switch issue {
                case .accessibility: return autoPasteEnabled
                case .model: return !model.isBusy
                default: return true
                }
            }
            return .needsAttention(shown)
        }
        if hasModelIssue {
            if case .downloading(let progress) = model {
                return .downloadingModel(percent: Int((progress.overallFraction * 100).rounded()))
            }
            return .downloadingModel(percent: nil)
        }
        if issues.contains(.accessibility) {
            return .needsAccessibility(autoPaste: autoPasteEnabled)
        }
        return .ready
    }

    var title: String {
        switch self {
        case .ready:
            return "You're all set"
        case .downloadingModel, .needsAccessibility:
            return "Almost ready"
        case .needsAttention:
            return "Setup needs attention"
        }
    }

    func message(toggleShortcut: String) -> String {
        switch self {
        case .ready:
            return "Press \(toggleShortcut) to start dictating, then press it again to stop."
        case .downloadingModel(let percent?):
            return "The speech model is downloading (\(percent)%). Dictation works as soon as it finishes."
        case .downloadingModel(nil):
            return "The speech model is downloading. Dictation works as soon as it finishes."
        case .needsAccessibility(autoPaste: false):
            return "Turn on Accessibility so \(toggleShortcut) works in every app. Until then, click the menu bar icon and choose Start Recording."
        case .needsAccessibility(autoPaste: true):
            return "Turn on Accessibility so \(toggleShortcut) and automatic paste work in every app. Until then, transcripts are copied to the clipboard."
        case .needsAttention:
            return "Fix the items below to start dictating. You can also fix them later in Settings."
        }
    }

    var completionButtonTitle: String {
        switch self {
        case .needsAttention:
            return "Continue to Superkeet"
        case .ready, .downloadingModel, .needsAccessibility:
            return "Start Using Superkeet"
        }
    }
}
