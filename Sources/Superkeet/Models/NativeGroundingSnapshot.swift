import Foundation

struct NativeActionPreflight: Equatable, Sendable {
    let window: NativeGroundingWindow
    let session: String
    let control: NativeGroundingSnapshot.Element
    let observationSchemaJSON: String
    var windowTitle: String?

    func refreshedArguments(_ json: String, snapshot: NativeGroundingSnapshot) throws -> String {
        let matches = snapshot.elements.filter { $0.sameControl(as: control) }
        guard snapshot.window == window, snapshot.windowTitle == windowTitle, matches.count == 1, let fresh = matches.first,
              fresh.enabled, fresh.editable == control.editable, fresh.pressable == control.pressable,
              fresh.valueState == control.valueState, fresh.token != control.token else {
            throw ActionChoiceError.invalid("the approved control changed; issue a new command")
        }
        var arguments = try NativeGroundingJSON.object(json)
        arguments["element_token"] = fresh.token
        return try NativeGroundingJSON.encode(arguments)
    }
}

struct NativeGroundingWindow: Equatable, Sendable {
    let pid: Int
    let windowID: Int

    static func resolve(_ json: String, app: String) throws -> Self {
        let root = try NativeGroundingJSON.object(json)
        guard let windows = root["windows"] as? [[String: Any]] else {
            throw ActionChoiceError.invalid("Driver returned no structured windows")
        }
        let matching = windows.filter {
            ($0["app_name"] as? String)?.localizedCaseInsensitiveCompare(app) == .orderedSame
                && $0["is_on_screen"] as? Bool == true && NativeGroundingJSON.integer($0["layer"]) == 0
        }
        guard matching.count == 1, let window = matching.first,
              let pid = NativeGroundingJSON.integer(window["pid"]), pid > 0,
              let windowID = NativeGroundingJSON.integer(window["window_id"]), windowID > 0 else {
            throw ActionChoiceError.invalid("the named app must have exactly one visible window")
        }
        return Self(pid: pid, windowID: windowID)
    }
}

struct NativeGroundingSnapshot: Sendable {
    struct Element: Equatable, Sendable {
        let index: Int
        let token: String
        let role: String
        let label: String
        let context: [String]
        let value: String?
        let valueState: String
        let enabled: Bool
        let editable: Bool
        let pressable: Bool

        func sameControl(as other: Self) -> Bool {
            role == other.role && label == other.label && context == other.context
        }

        func matches(target: String) -> Bool {
            let ignored: Set<String> = ["the", "a", "an", "button", "field", "textbox", "checkbox", "radio", "in", "section"]
            func words(_ text: String) -> Set<String> {
                Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)).subtracting(ignored)
            }
            let requested = words(target)
            return !requested.isEmpty && requested.isSubset(of: words(([label] + context).joined(separator: " ")))
        }
    }

    let captureID: String
    let window: NativeGroundingWindow
    let windowTitle: String?
    let elements: [Element]

    init(json: String, window: NativeGroundingWindow) throws {
        let root = try NativeGroundingJSON.object(json)
        guard let snapshot = root["snapshot_id"] as? String,
              snapshot.range(of: #"\As[0-9a-f]{8}\z"#, options: .regularExpression) != nil,
              NativeGroundingJSON.integer(root["window_id"]) == window.windowID,
              root["truncated"] as? Bool != true, root["has_more"] as? Bool != true,
              let rows = root["elements"] as? [[String: Any]], rows.count < 2_000 else {
            throw ActionChoiceError.invalid("Driver returned an invalid or wrong-window accessibility snapshot")
        }
        if root["pid"] != nil, NativeGroundingJSON.integer(root["pid"]) != window.pid {
            throw ActionChoiceError.invalid("accessibility snapshot belongs to another process")
        }
        var byIndex: [Int: [String: Any]] = [:]
        for row in rows {
            guard let index = NativeGroundingJSON.integer(row["element_index"]), index >= 0, byIndex[index] == nil else {
                throw ActionChoiceError.invalid("duplicate or invalid accessibility element index")
            }
            byIndex[index] = row
        }
        let roots = rows.filter { $0["role"] as? String == "AXWindow" && NativeGroundingJSON.integer($0["depth"]) == 0 }
        guard roots.count == 1, let rootIndex = NativeGroundingJSON.integer(roots.first?["element_index"]) else {
            throw ActionChoiceError.invalid("accessibility snapshot has no unique window root")
        }
        self.window = window
        self.windowTitle = root["window_title"] as? String
        self.captureID = "ax:\(window.pid):\(window.windowID):\(snapshot)"
        self.elements = rows.compactMap { row in
            guard let index = NativeGroundingJSON.integer(row["element_index"]), let role = row["role"] as? String,
                  let label = row["label"] as? String, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let token = row["element_token"] as? String, token == "\(snapshot):\(index)",
                  let ancestors = Self.ancestors(of: index, root: rootIndex, rows: byIndex),
                  !ancestors.contains(where: { $0["role"] as? String == "AXWebArea" }),
                  let valueState = try? NativeGroundingJSON.encode(["value": row["value"] ?? NSNull()]) else { return nil }
            let context = ancestors.filter { $0["role"] as? String != "AXWindow" }.compactMap { $0["label"] as? String }
            let disabled = ([row] + ancestors).contains { $0["enabled"] as? Bool == false || $0["visible"] as? Bool == false }
            let editable = ["AXTextField", "AXTextArea", "AXComboBox"].contains(role)
                && row["readonly"] as? Bool != true && row["editable"] as? Bool != false
                && row["subrole"] as? String != "AXSecureTextField"
            return Element(index: index, token: token, role: role, label: label, context: context,
                           value: row["value"] as? String, valueState: valueState, enabled: !disabled, editable: editable,
                           pressable: ["AXButton", "AXCheckBox", "AXRadioButton", "AXMenuItem", "AXLink", "AXTab"].contains(role)
                               && (row["actions"] as? [String] ?? []).contains("AXPress"))
        }
    }

    func candidates(step: NativeActionStep, tool: ActionToolSpec, session: String) throws -> [ActionCandidate] {
        let eligible = elements.filter {
            $0.enabled && (step.operation == .setText ? $0.editable : $0.pressable)
                && $0.matches(target: step.target)
        }
        guard eligible.count <= 30 else { throw ActionChoiceError.invalid("too many matching controls; name a narrower target") }
        return try eligible.enumerated().map { offset, element in
            let role = step.operation == .setText ? "textbox" : element.role.replacingOccurrences(of: "AX", with: "").lowercased()
            let verb = step.operation == .setText ? "Type \(NativeGroundingJSON.quote(step.text ?? "")) into" : "Click"
            var description = "\(verb) \(role) \(NativeGroundingJSON.quote(element.label))"
            if !element.context.isEmpty { description += "; section=\(element.context.joined(separator: " / "))" }
            var arguments: [String: Any] = ["pid": window.pid, "window_id": window.windowID,
                                            "element_token": element.token, "session": session]
            if step.operation == .setText { arguments["value"] = step.text ?? "" }
            return ActionCandidate(id: "a\(offset)", description: description, tool: tool,
                                   argumentsJSON: try NativeGroundingJSON.encode(arguments), captureID: captureID)
        } + ActionCandidate.reserved
    }

    func selectedElement(_ candidate: ActionCandidate) throws -> Element {
        let arguments = try NativeGroundingJSON.object(candidate.argumentsJSON)
        guard let token = arguments["element_token"] as? String,
              let selected = elements.first(where: { $0.token == token }),
              elements.filter({ $0.sameControl(as: selected) }).count == 1 else {
            throw ActionChoiceError.invalid("the selected control is missing or ambiguous")
        }
        return selected
    }

    func verifies(text: String, control: Element) -> Bool {
        let matches = elements.filter { $0.sameControl(as: control) }
        return matches.count == 1 && matches.first?.value == text
    }

    private static func ancestors(of index: Int, root: Int, rows: [Int: [String: Any]]) -> [[String: Any]]? {
        var current = index
        var visited = Set<Int>()
        var ancestors: [[String: Any]] = []
        while current != root {
            guard visited.insert(current).inserted, let parent = NativeGroundingJSON.integer(rows[current]?["parent_index"]),
                  let row = rows[parent] else { return nil }
            ancestors.append(row)
            current = parent
        }
        return ancestors.reversed()
    }
}
