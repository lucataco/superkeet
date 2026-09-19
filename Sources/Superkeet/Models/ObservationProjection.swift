import Foundation

/// Turns a computer-use server's structured observation into the short text a
/// small on-device model can actually use. A raw `get_window_state` result for
/// Notes is 40 KB of JSON (or 13 KB of markdown) dominated by menu items,
/// unlabeled rows, and the full note body; truncating that to 800 characters
/// discards every useful control. The projection keeps labeled, actionable
/// elements, ranks them by the words of the current step, never includes long
/// text values, and folds the menu bar down to the items that match.
enum ObservationProjection {
    static let defaultLimit = ActionResultText.modelLimit
    static let labelLimit = 48
    static let valueLimit = 32

    /// Compact text for a `get_window_state`, `list_windows`, or `list_apps`
    /// result, or `nil` when the JSON has none of those shapes.
    static func compact(json: String, focus: Set<String>, limit: Int = defaultLimit) -> String? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let rows = root["elements"] as? [[String: Any]] {
            return windowState(root: root, rows: rows, focus: focus, limit: limit)
        }
        if let windows = root["windows"] as? [[String: Any]] {
            return windowList(windows, focus: focus, limit: limit)
        }
        if let apps = root["apps"] as? [[String: Any]] {
            return appList(apps, focus: focus, limit: limit)
        }
        return nil
    }

    // MARK: Window state

    private static let menuRoles: Set<String> = ["AXMenuBar", "AXMenuBarItem", "AXMenu", "AXMenuItem"]
    private static let containerRoles: Set<String> = ["AXWindow", "AXGroup", "AXScrollArea", "AXSplitGroup", "AXToolbar", "AXList", "AXOutline", "AXTable", "AXRow", "AXCell", "AXColumn", "AXLayoutArea", "AXTabGroup"]
    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    private static let stopwords: Set<String> = ["the", "a", "an", "and", "then", "to", "in", "into", "on", "of", "for", "with", "my", "this", "that", "it", "please", "new", "create", "make", "open", "click", "press", "type", "app"]

    private struct Row {
        let index: Int
        let role: String
        let label: String
        let value: String?
        let enabled: Bool
        let menuPath: [String]
        let score: Int
    }

    private static func windowState(root: [String: Any], rows: [[String: Any]], focus: Set<String>, limit: Int) -> String {
        let byIndex = Dictionary(rows.compactMap { row in NativeGroundingJSON.integer(row["element_index"]).map { ($0, row) } },
                                 uniquingKeysWith: { first, _ in first })
        let terms = focusTerms(focus)
        var candidates: [Row] = []
        for row in rows {
            guard let index = NativeGroundingJSON.integer(row["element_index"]), let role = row["role"] as? String else { continue }
            let rawLabel = (row["label"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let value = (row["value"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let isText = textRoles.contains(role)
            let label = isText && rawLabel.count > labelLimit && rawLabel == value ? "" : rawLabel
            // Containers and unlabeled elements carry nothing a model can name.
            guard !containerRoles.contains(role) || !label.isEmpty, !label.isEmpty || isText, !isInternalIdentifier(label) else { continue }
            let ancestors = ancestorLabels(of: index, in: byIndex)
            let menuPath = menuRoles.contains(role) ? ancestors.filter { !$0.isEmpty } : []
            let enabled = row["enabled"] as? Bool ?? true
            let haystack = words(([label] + ancestors + [value ?? ""]).joined(separator: " "))
            var score = terms.intersection(haystack).count * 10
            if menuRoles.contains(role) {
                // Menus are only worth listing when the step asked for something in them.
                guard role == "AXMenuItem", score > 0, enabled else { continue }
                score -= 1
            } else if isText {
                score += 2
            } else if role == "AXButton" || role == "AXMenuButton" || role == "AXCheckBox" || role == "AXPopUpButton" || role == "AXTab" || role == "AXLink" {
                score += 3
            }
            if !enabled { score -= 5 }
            candidates.append(Row(index: index, role: role, label: label, value: value, enabled: enabled, menuPath: menuPath, score: score))
        }
        candidates.sort { ($0.score, -$0.index) > ($1.score, -$1.index) }

        let appName = root["app_name"] as? String
        var header = appName ?? "Window"
        if let title = root["window_title"] as? String, !title.isEmpty, title != appName { header += " — “\(clip(title, labelLimit))”" }
        var details: [String] = []
        if let snapshot = root["snapshot_id"] as? String { details.append("snapshot \(snapshot)") }
        details.append("\(rows.count) elements; use element_index or element_token")
        header += " (" + details.joined(separator: ", ") + ")"

        var lines = [header]
        var used = header.count
        var shown = 0
        for row in candidates {
            let line = render(row)
            guard used + line.count + 1 <= limit - 24 else { break }
            lines.append(line)
            used += line.count + 1
            shown += 1
        }
        if shown < candidates.count { lines.append("… \(candidates.count - shown) more elements not shown") }
        return lines.joined(separator: "\n")
    }

    private static func render(_ row: Row) -> String {
        var text = "[\(row.index)] \(row.role.replacingOccurrences(of: "AX", with: ""))"
        if !row.menuPath.isEmpty { text += " " + row.menuPath.joined(separator: " ▸ ") + " ▸" }
        if !row.label.isEmpty { text += " “\(clip(row.label, labelLimit))”" }
        if let value = row.value, !value.isEmpty, value != row.label {
            // Multi-line bodies are the user's content, not UI; report only their size.
            if row.role == "AXTextArea" || value.contains("\n") || value.count > valueLimit * 4 {
                text += " = (\(value.count) characters)"
            } else {
                text += " = “\(clip(value, valueLimit))”"
            }
        }
        if !row.enabled { text += " (disabled)" }
        return text
    }

    private static func ancestorLabels(of index: Int, in rows: [Int: [String: Any]]) -> [String] {
        var labels: [String] = []
        var current = index
        var visited = Set<Int>()
        while let parent = NativeGroundingJSON.integer(rows[current]?["parent_index"]), visited.insert(parent).inserted, let row = rows[parent] {
            if row["role"] as? String != "AXWindow", let label = row["label"] as? String, !label.isEmpty, !isInternalIdentifier(label) {
                labels.append(label)
            }
            current = parent
        }
        return labels.reversed()
    }

    /// Accessibility identifiers leak through as labels on some apps
    /// (`_NS:322`, `ICMNoteListCell, Note[id=…]`, `<<Import - unlocalized>>`).
    static func isInternalIdentifier(_ label: String) -> Bool {
        label.hasPrefix("_") || label.contains("[id=") || label.hasPrefix("<<") || label.range(of: #"\A[A-Za-z]+[A-Z][A-Za-z]*Cell\b"#, options: .regularExpression) != nil
    }

    // MARK: Window and app lists

    private static func windowList(_ windows: [[String: Any]], focus: Set<String>, limit: Int) -> String {
        let terms = focusTerms(focus)
        let ranked = windows.sorted { lhs, rhs in
            let lhsOn = lhs["is_on_screen"] as? Bool == true, rhsOn = rhs["is_on_screen"] as? Bool == true
            if lhsOn != rhsOn { return lhsOn }
            let lhsMatch = terms.intersection(words("\(lhs["app_name"] ?? "") \(lhs["title"] ?? "")")).count
            let rhsMatch = terms.intersection(words("\(rhs["app_name"] ?? "") \(rhs["title"] ?? "")")).count
            if lhsMatch != rhsMatch { return lhsMatch > rhsMatch }
            return (NativeGroundingJSON.integer(lhs["z_index"]) ?? -1) > (NativeGroundingJSON.integer(rhs["z_index"]) ?? -1)
        }
        var lines = ["\(windows.count) windows (pid, window_id, app, title; on-screen first):"]
        var used = lines[0].count
        var shown = 0
        for window in ranked {
            let app = window["app_name"] as? String ?? "?"
            let title = (window["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var line = "pid \(NativeGroundingJSON.integer(window["pid"]) ?? 0) window \(NativeGroundingJSON.integer(window["window_id"]) ?? 0) \(app)"
            if !title.isEmpty, title != app { line += " “\(clip(title, labelLimit))”" }
            if window["is_on_screen"] as? Bool != true { line += " (off screen)" }
            guard used + line.count + 1 <= limit - 24 else { break }
            lines.append(line)
            used += line.count + 1
            shown += 1
        }
        if shown < windows.count { lines.append("… \(windows.count - shown) more windows not shown") }
        return lines.joined(separator: "\n")
    }

    private static func appList(_ apps: [[String: Any]], focus: Set<String>, limit: Int) -> String {
        let terms = focusTerms(focus)
        let ranked = apps.sorted { lhs, rhs in
            let lhsMatch = terms.intersection(words("\(lhs["name"] ?? "")")).count, rhsMatch = terms.intersection(words("\(rhs["name"] ?? "")")).count
            if lhsMatch != rhsMatch { return lhsMatch > rhsMatch }
            let lhsRunning = lhs["running"] as? Bool == true, rhsRunning = rhs["running"] as? Bool == true
            if lhsRunning != rhsRunning { return lhsRunning }
            return "\(lhs["name"] ?? "")".localizedCaseInsensitiveCompare("\(rhs["name"] ?? "")") == .orderedAscending
        }
        var lines = ["\(apps.count) apps (running first; use bundle_id with launch_app):"]
        var used = lines[0].count
        var shown = 0
        for app in ranked {
            var line = "\(app["name"] as? String ?? "?")"
            if let bundle = app["bundle_id"] as? String, !bundle.isEmpty { line += " \(bundle)" }
            if app["running"] as? Bool == true { line += " running pid \(NativeGroundingJSON.integer(app["pid"]) ?? 0)" }
            if app["active"] as? Bool == true { line += " (frontmost)" }
            guard used + line.count + 1 <= limit - 24 else { break }
            lines.append(line)
            used += line.count + 1
            shown += 1
        }
        if shown < apps.count { lines.append("… \(apps.count - shown) more apps not shown") }
        return lines.joined(separator: "\n")
    }

    // MARK: Helpers

    static func focusTerms(_ focus: Set<String>) -> Set<String> {
        Set(focus.map { $0.lowercased() }).subtracting(stopwords).filter { $0.count >= 3 }
    }

    private static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
}
