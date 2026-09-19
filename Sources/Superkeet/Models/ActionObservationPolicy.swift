import Foundation

/// Decides which read-only tools describe live UI or system state. Their
/// results must never be served from the per-run cache: apps launch, windows
/// appear, and pages load between calls without any Superkeet action, so a
/// repeated observation is a request for the current state, not a duplicate.
enum ActionObservationPolicy {
    /// Known observation tools from the default servers (Cua Driver and Chrome
    /// DevTools) whose names do not all follow a recognizable prefix.
    private static let liveStateNames: Set<String> = [
        // Cua Driver
        "list_apps", "list_windows", "get_window_state", "get_accessibility_tree", "verify_state",
        "get_browser_state", "get_desktop_state", "get_cursor_position", "get_screen_size",
        "clipboard_read", "zoom", "check_permissions", "health_report",
        // Chrome DevTools
        "list_pages", "take_snapshot", "take_screenshot", "evaluate_script",
        "list_console_messages", "list_network_requests", "get_network_request", "get_console_message"
    ]

    private static let liveStatePrefixes = ["list_", "get_", "take_", "verify_", "inspect_", "observe_"]
    private static let liveStateFragments = ["snapshot", "screenshot"]

    /// Whether a tool's output reflects state that can change between calls.
    /// Only read-only tools qualify; a mutating tool is never treated as an
    /// observation even if its name looks like one.
    static func reflectsLiveState(_ spec: ActionToolSpec) -> Bool {
        guard spec.risk == .readOnly else { return false }
        let name = spec.toolName.lowercased()
        if liveStateNames.contains(name) { return true }
        if liveStatePrefixes.contains(where: { name.hasPrefix($0) }) { return true }
        return liveStateFragments.contains { name.contains($0) }
    }

    /// Observations whose structured results `ObservationProjection` knows how
    /// to condense for the planner.
    private static let projectedNames: Set<String> = ["get_window_state", "list_windows", "list_apps", "get_accessibility_tree"]

    static func projectsForPlanner(_ spec: ActionToolSpec) -> Bool {
        spec.risk == .readOnly && projectedNames.contains(spec.toolName.lowercased())
    }

    /// Flags live observations so `AgentSessionController` bypasses its result
    /// cache for them, and marks the ones whose results are projected into
    /// compact text. Specs that are already flagged are left unchanged.
    static func markingLiveObservations(_ tools: [ActionToolSpec]) -> [ActionToolSpec] {
        tools.map { spec in
            var marked = spec
            if !spec.requiresFreshObservation, reflectsLiveState(spec) { marked.requiresFreshObservation = true }
            if projectsForPlanner(spec) { marked.compactObservation = true }
            return marked
        }
    }
}
