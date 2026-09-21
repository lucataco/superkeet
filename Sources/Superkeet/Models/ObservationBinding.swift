import Foundation

/// The handles a computer-use server hands back with each observation (snapshot ids, element
/// tokens, pids, window ids, session labels). Superkeet keeps them here so the on-device model
/// never has to repeat them: it names a control by its `element_index` from the latest
/// observation and Superkeet fills in the rest before the call leaves the app. Every one of
/// these fields was hallucinated by the model when it had to supply them itself.
struct ObservationBinding: Equatable, Sendable {
    struct WindowRef: Equatable, Sendable {
        let pid: Int
        let windowID: Int
    }

    var pid: Int?
    var windowID: Int?
    var snapshotID: String?
    /// A session label the server issued, used only without a per-command label.
    var session: String?
    /// Superkeet's own label for every tool accepting a session in this command.
    var sessionLabel: String?
    var elementTokens: [Int: String] = [:]
    /// Frontmost window per process, from `list_windows`.
    var windowsByPID: [Int: Int] = [:]
    var observedWindowsByPID: [Int: Set<Int>] = [:]
    var frontmost: WindowRef?
    /// The active app from `list_apps`.
    var activePID: Int?

    /// Learns from a structured observation result. Results of unknown shape leave the binding as it was.
    mutating func absorb(resultJSON: String, toolName: String) {
        guard let data = resultJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let label = root["session"] as? String, !label.isEmpty { session = label }
        if toolName == "get_window_state", root["window_id"] != nil {
            absorbWindowState(root, elements: root["elements"] as? [[String: Any]] ?? [])
        } else if toolName == "list_windows", let windows = root["windows"] as? [[String: Any]] {
            absorbWindows(windows)
        } else if toolName == "list_apps", let apps = root["apps"] as? [[String: Any]] {
            if let active = apps.first(where: { $0["active"] as? Bool == true }), let pid = ActionJSON.integer(active["pid"]) {
                activePID = pid
            }
        }
    }

    private mutating func absorbWindowState(_ root: [String: Any], elements: [[String: Any]]) {
        guard let observedPID = ActionJSON.integer(root["pid"]), observedPID > 0,
              let observedWindow = ActionJSON.integer(root["window_id"]), observedWindow > 0 else { return }
        pid = observedPID
        windowID = observedWindow
        snapshotID = root["snapshot_id"] as? String
        observedWindowsByPID[observedPID, default: []].insert(observedWindow)
        var tokens: [Int: String] = [:]
        for element in elements {
            guard let index = ActionJSON.integer(element["element_index"]),
                  let token = element["element_token"] as? String, !token.isEmpty else { continue }
            tokens[index] = token
        }
        elementTokens = tokens
        if let pid, let windowID { windowsByPID[pid] = windowID }
    }

    private mutating func absorbWindows(_ windows: [[String: Any]]) {
        // On-screen windows rank above off-screen ones; among those, the highest z-index is in front.
        var best: [Int: (windowID: Int, rank: Int)] = [:]
        var top: (ref: WindowRef, rank: Int)?
        for window in windows {
            guard let pid = ActionJSON.integer(window["pid"]), pid > 0,
                  let windowID = ActionJSON.integer(window["window_id"]), windowID > 0 else { continue }
            observedWindowsByPID[pid, default: []].insert(windowID)
            let z = ActionJSON.integer(window["z_index"]) ?? -1
            let onScreen = window["is_on_screen"] as? Bool ?? true
            let rank = (onScreen ? 1_000_000 : 0) + max(-1, min(z, 999_999))
            if best[pid].map({ rank > $0.rank }) ?? true {
                best[pid] = (windowID, rank)
            }
            if top.map({ rank > $0.rank }) ?? true {
                top = (WindowRef(pid: pid, windowID: windowID), rank)
            }
        }
        for (pid, entry) in best { windowsByPID[pid] = entry.windowID }
        if let top { frontmost = top.ref }
    }

    static func newSessionLabel() -> String {
        "sk-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8)
    }

    /// The pid whose window the call needs but Superkeet has not seen: the caller can fetch the
    /// window list for it and complete the arguments again.
    func missingWindowPID(argumentsJSON: String, schemaJSON: String) -> Int? {
        guard let schemaData = schemaJSON.data(using: .utf8),
              let schema = try? JSONSerialization.jsonObject(with: schemaData) as? [String: Any],
              let properties = schema["properties"] as? [String: Any], properties["window_id"] != nil,
              let data = argumentsJSON.data(using: .utf8),
              let arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = ActionJSON.integer(arguments["pid"]), pid > 0 else { return nil }
        if let window = ActionJSON.integer(arguments["window_id"]), observedWindowsByPID[pid]?.contains(window) == true { return nil }
        return pid
    }

    /// Fills in what the call needs and the model did not, or could not, supply. `currentPID` is
    /// the app the command is acting in; it wins over stale observations unless the call names an
    /// element, which belongs to the window the snapshot came from.
    func completing(argumentsJSON: String, schemaJSON: String, currentPID: Int?, toolName: String = "") -> String {
        guard let schemaData = schemaJSON.data(using: .utf8),
              let schema = try? JSONSerialization.jsonObject(with: schemaData) as? [String: Any],
              let properties = schema["properties"] as? [String: Any] else { return argumentsJSON }
        var arguments: [String: Any] = [:]
        if !argumentsJSON.isEmpty, let data = argumentsJSON.data(using: .utf8) {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return argumentsJSON }
            arguments = object
        }
        let accepts = Set(properties.keys)
        let original = arguments

        for key in ObservationHandles.modelNeverSets { arguments.removeValue(forKey: key) }

        if accepts.contains("session") {
            if let session = sessionLabel ?? session {
                arguments["session"] = session
            } else {
                arguments.removeValue(forKey: "session")
            }
        }

        let elementIndex = ActionJSON.integer(arguments["element_index"])
        let targetsElement = elementIndex != nil
        if accepts.contains("pid"), (ActionJSON.integer(arguments["pid"]) ?? 0) <= 0 {
            let candidate = targetsElement ? (pid ?? currentPID) : (currentPID ?? pid ?? activePID ?? frontmost?.pid)
            if let candidate, candidate > 0 { arguments["pid"] = candidate } else { arguments.removeValue(forKey: "pid") }
        }
        let resolvedPID = ActionJSON.integer(arguments["pid"])
        let suppliedWindow = ActionJSON.integer(arguments["window_id"])
        let observedWindow = resolvedPID.flatMap { observedWindowsByPID[$0] }?.contains(suppliedWindow ?? 0) == true
        if accepts.contains("window_id"), let suppliedWindow, suppliedWindow > 0, !observedWindow {
            // Leave it missing for the controller to fetch a fresh list before choosing a window.
            arguments.removeValue(forKey: "window_id")
        } else if accepts.contains("window_id"), !observedWindow {
            var candidate: Int?
            if targetsElement, resolvedPID == pid {
                candidate = windowID
            } else if let resolvedPID {
                candidate = windowsByPID[resolvedPID] ?? (resolvedPID == pid ? windowID : nil) ?? (resolvedPID == frontmost?.pid ? frontmost?.windowID : nil)
            }
            if let candidate, candidate > 0 { arguments["window_id"] = candidate } else { arguments.removeValue(forKey: "window_id") }
        }

        if let elementIndex {
            if accepts.contains("element_token") {
                if let token = elementTokens[elementIndex] { arguments["element_token"] = token } else { arguments.removeValue(forKey: "element_token") }
            }
            if accepts.contains("snapshot_id") {
                if let snapshotID { arguments["snapshot_id"] = snapshotID } else { arguments.removeValue(forKey: "snapshot_id") }
            }
        } else {
            // A token or snapshot the model produced on its own is never one of ours.
            if let token = arguments["element_token"] as? String, !elementTokens.values.contains(token) { arguments.removeValue(forKey: "element_token") }
            if let snapshot = arguments["snapshot_id"] as? String, snapshot != snapshotID { arguments.removeValue(forKey: "snapshot_id") }
        }

        guard NSDictionary(dictionary: arguments) != NSDictionary(dictionary: original),
              JSONSerialization.isValidJSONObject(arguments),
              let output = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]),
              let string = String(data: output, encoding: .utf8) else { return argumentsJSON }
        return string
    }
}

enum ObservationHandles {
    /// Properties Superkeet manages on the model's behalf. They are removed from the schema the
    /// model sees, so it cannot invent them, and filled in from the binding before the call.
    static let hidden: Set<String> = [
        "session", "element_token", "snapshot_id", "delivery_mode", "from_zoom", "debug_image_out",
        "capture_mode", "max_dimension", "screenshot_out_file"
    ]

    /// Hidden properties that never get a value from Superkeet either; they are stripped.
    static let modelNeverSets: Set<String> = ["delivery_mode", "from_zoom", "debug_image_out", "capture_mode", "max_dimension", "screenshot_out_file"]

    /// Whether a tool takes any handle Superkeet fills in, so the planner can be told so.
    static func managesHandles(in schemaJSON: String) -> Bool {
        guard let data = schemaJSON.data(using: .utf8),
              let schema = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let properties = schema["properties"] as? [String: Any] else { return false }
        return !Set(properties.keys).isDisjoint(with: ["element_token", "snapshot_id", "session"])
    }
}
