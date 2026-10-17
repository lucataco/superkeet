import Foundation

/// Decides how long to wait for the speech engine to settle after a cancel before restarting it.
///
/// The engine acknowledges `cancel` with `state: "transcribing"`: it flips the session phase
/// before its worker drains the remaining audio and clears the session, which takes a moment.
/// Restarting on that first reply threw away a healthy engine on every cancel. Instead, probe
/// `status` a few times and restart only if the engine never returns to idle.
enum EngineCancelPolicy {
    enum Step: Equatable {
        case poll(delay: Duration?)
        case settle
    }

    static let maximumPolls = 10
    static let pollInterval: Duration = .milliseconds(150)

    static func nextStep(engineState: String?, polls: Int) -> Step {
        if engineState == "idle" { return .settle }
        guard polls < maximumPolls else { return .settle }
        if engineState == nil, polls == 0 { return .poll(delay: nil) }
        return .poll(delay: pollInterval)
    }
}
