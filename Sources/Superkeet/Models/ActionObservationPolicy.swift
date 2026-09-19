import Foundation

enum ActionObservationPolicy {
    private static let liveStateNames: Set<String> = [
        "list_apps", "list_windows", "get_window_state", "get_accessibility_tree", "verify_state",
        "get_browser_state", "get_desktop_state", "get_cursor_position", "get_screen_size",
        "clipboard_read", "zoom", "check_permissions", "health_report",
        "list_pages", "take_snapshot", "take_screenshot", "evaluate_script",
        "list_console_messages", "list_network_requests", "get_network_request", "get_console_message"
    ]

    private static let liveStatePrefixes = ["list_", "get_", "take_", "verify_", "inspect_", "observe_"]
    private static let liveStateFragments = ["snapshot", "screenshot"]

    static func reflectsLiveState(_ spec: ActionToolSpec) -> Bool {
        guard spec.risk == .readOnly else { return false }
        let name = spec.toolName.lowercased()
        if liveStateNames.contains(name) { return true }
        if liveStatePrefixes.contains(where: { name.hasPrefix($0) }) { return true }
        return liveStateFragments.contains { name.contains($0) }
    }

    private static let projectedNames: Set<String> = ["get_window_state", "list_windows", "list_apps", "get_accessibility_tree"]

    static func projectsForPlanner(_ spec: ActionToolSpec) -> Bool {
        spec.risk == .readOnly && projectedNames.contains(spec.toolName.lowercased())
    }

    static func markingLiveObservations(_ tools: [ActionToolSpec]) -> [ActionToolSpec] {
        tools.map { spec in
            var marked = spec
            if !spec.requiresFreshObservation, reflectsLiveState(spec) { marked.requiresFreshObservation = true }
            if projectsForPlanner(spec) { marked.compactObservation = true }
            return marked
        }
    }
}
