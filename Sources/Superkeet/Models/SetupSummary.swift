enum SetupSummary: Equatable {
    case ready
    case downloadingModel(percent: Int?, needsAccessibility: Bool, autoPaste: Bool)
    case needsAccessibility(autoPaste: Bool)
    case needsAttention([AppReadinessIssue])

    static func make(report: AppReadinessReport, model: ModelProvisionState, autoPasteEnabled: Bool) -> SetupSummary {
        let issues = report.issues.filter { $0 != .appleIntelligence }
        let modelDownloading = issues.contains(.model) && model.isBusy
        let shown = issues.filter { $0 != .model || !modelDownloading }
        if shown.contains(where: { $0 != .accessibility }) {
            return .needsAttention(shown)
        }
        let needsAccessibility = shown.contains(.accessibility)
        if modelDownloading {
            return .downloadingModel(percent: downloadPercent(model), needsAccessibility: needsAccessibility, autoPaste: autoPasteEnabled)
        }
        if needsAccessibility {
            return .needsAccessibility(autoPaste: autoPasteEnabled)
        }
        return .ready
    }

    private static func downloadPercent(_ model: ModelProvisionState) -> Int? {
        guard case .downloading(let progress) = model else { return nil }
        return Int((progress.overallFraction * 100).rounded())
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
        case .downloadingModel(let percent, let needsAccessibility, let autoPaste):
            let progress = percent.map { " (\($0)%)" } ?? ""
            let next: String
            if !needsAccessibility {
                next = "Dictation works as soon as it finishes."
            } else if autoPaste {
                next = "Turn on Accessibility now so \(toggleShortcut) and automatic paste work when it finishes."
            } else {
                next = "Turn on Accessibility now so \(toggleShortcut) works when it finishes."
            }
            return "The speech model is downloading\(progress). \(next)"
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
