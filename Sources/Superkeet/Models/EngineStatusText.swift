import Foundation

/// Menu status while the speech engine isn't running. Stopping after the idle timeout is normal,
/// so only a real problem should read like one.
enum EngineStatusText {
    static func whileStopped(daemonState: ParakeetService.DaemonState, model: ModelProvisionState, runtimeIssue: String?) -> String {
        switch model {
        case .downloading(let progress):
            return "Downloading speech model… \(Int((progress.overallFraction * 100).rounded()))%"
        case .checking:
            return "Checking speech model…"
        case .verifying:
            return "Verifying speech model…"
        default:
            break
        }
        switch daemonState {
        case .starting: return "Getting ready…"
        case .stopping: return "Stopping…"
        default: break
        }
        if case .notInstalled = model { return "Speech model missing. Open Settings to download it." }
        if case .failed = model { return "Speech model download failed. Open Settings to retry." }
        if runtimeIssue != nil { return "Dictation stopped. Open Settings for details." }
        return "Ready"
    }
}
