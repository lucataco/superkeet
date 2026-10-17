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
        case .starting: return "Starting speech engine…"
        case .stopping: return "Stopping speech engine…"
        default: break
        }
        if case .notInstalled = model { return "Speech model not installed — run Setup" }
        if case .failed = model { return "Speech model download failed — see Settings" }
        if runtimeIssue != nil { return "Speech engine stopped — see Settings" }
        return "Ready — the engine starts when you record"
    }
}
