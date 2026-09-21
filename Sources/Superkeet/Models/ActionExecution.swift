import Foundation

struct ActionToolSpec: Identifiable, Equatable, Sendable {
    let serverID: UUID
    let serverName: String
    let toolName: String
    let displayName: String
    let description: String
    let risk: ActionToolRisk
    let inputSchemaJSON: String
    var approvalExempt = false
    var requiresFreshObservation = false
    var compactObservation = false

    var id: String { "\(serverID.uuidString)/\(toolName)" }

    init(descriptor: MCPToolDescriptor) {
        self.serverID = descriptor.serverID
        self.serverName = descriptor.serverName
        self.toolName = descriptor.name
        self.displayName = descriptor.displayName
        self.description = descriptor.description ?? ""
        self.risk = descriptor.risk
        self.inputSchemaJSON = descriptor.inputSchemaJSON
    }
}

struct ActionApprovalRequest: Identifiable, Equatable, Sendable {
    let id = UUID()
    let tool: ActionToolSpec
    let argumentsJSON: String
}

enum ActionApprovalDecision: Equatable {
    case approve
    case deny
}

enum ActionPlanEvent: Equatable {
    case planning
    case message(String)
    case toolStarted(ActionToolSpec)
    case toolFinished(ActionToolSpec, String)
    case toolFailed(ActionToolSpec, String)
    case toolDenied(ActionToolSpec)
    case toolReused(ActionToolSpec)
}

enum ActionExecutionError: LocalizedError, Equatable {
    case unavailable
    case noTools
    case noMCPServersEnabled
    case activeChromeTabUnavailable
    case approvalDenied(String)
    case planDenied
    case stepBudgetExceeded
    case timedOut
    case runDeadlineExceeded(seconds: Int)
    case cancelled
    case argumentsTooLarge

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Actions Mode needs macOS 26 with Apple Intelligence enabled."
        case .noTools:
            return "No MCP tools are available. Add and enable an MCP server in Settings > Actions."
        case .noMCPServersEnabled:
            return "No MCP servers are enabled. Enable a server in Settings > Actions for this request."
        case .activeChromeTabUnavailable:
            return "Active-tab requests require one enabled Chrome DevTools server connected to your running Chrome profile. Enable chrome-devtools in Settings > Actions and allow the connection in Chrome."
        case .approvalDenied(let tool):
            return "The action was not approved, so '\(tool)' did not run."
        case .planDenied:
            return "The plan was not approved, so no further steps ran."
        case .stepBudgetExceeded:
            return "The action used too many steps and was stopped."
        case .timedOut:
            return "The action took too long and was stopped."
        case .runDeadlineExceeded(let seconds):
            return "The command did not finish within \(seconds) seconds and was stopped."
        case .cancelled:
            return "The action was cancelled."
        case .argumentsTooLarge:
            return "The tool arguments were too large to run safely."
        }
    }
}

enum ActionLimits {
    static let maximumToolsPerAction = 40
    static let maximumArgumentsBytes = 64 * 1_024

    static func limitedTools(_ tools: [ActionToolSpec]) -> [ActionToolSpec] {
        guard tools.count > maximumToolsPerAction else { return tools }
        return Array(tools.prefix(maximumToolsPerAction))
    }

    static func validateArguments(_ json: String) throws {
        guard json.utf8.count > maximumArgumentsBytes else { return }
        throw ActionExecutionError.argumentsTooLarge
    }

    static func estimatedTokenCost(of tool: ActionToolSpec) -> Int {
        ActionToolSchema.estimatedTokenCost(of: tool)
    }

    static func prioritizedTools(_ tools: [ActionToolSpec], task: String) -> [ActionToolSpec] {
        prioritizedTools(tools, intent: HeuristicIntentExtractor.intent(for: task))
    }

    static func prioritizedTools(_ tools: [ActionToolSpec], intent: ActionIntent) -> [ActionToolSpec] {
        var scores: [String: Int] = [:]
        var preferences: [String: Int] = [:]
        for tool in tools {
            scores[tool.id] = relevanceScore(of: tool, intent: intent)
            preferences[tool.id] = preferenceIndex(of: tool, intent: intent)
        }
        var byServer: [UUID: [ActionToolSpec]] = [:]
        var serverOrder: [UUID] = []
        for tool in tools {
            if byServer[tool.serverID] == nil {
                byServer[tool.serverID] = []
                serverOrder.append(tool.serverID)
            }
            byServer[tool.serverID]?.append(tool)
        }
        for id in serverOrder {
            byServer[id]?.sort {
                let lhsPreference = preferences[$0.id] ?? Int.max
                let rhsPreference = preferences[$1.id] ?? Int.max
                if intent.scope == .activeTab, lhsPreference != rhsPreference { return lhsPreference < rhsPreference }
                let lhs = scores[$0.id] ?? 0
                let rhs = scores[$1.id] ?? 0
                if lhs != rhs { return lhs > rhs }
                if lhsPreference != rhsPreference { return lhsPreference < rhsPreference }
                let displayOrder = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                if displayOrder != .orderedSame { return displayOrder == .orderedAscending }
                return $0.id < $1.id
            }
        }
        serverOrder.sort {
            let lhs = byServer[$0]?.first.flatMap { scores[$0.id] } ?? 0
            let rhs = byServer[$1]?.first.flatMap { scores[$0.id] } ?? 0
            if lhs != rhs { return lhs > rhs }
            let lhsCount = byServer[$0]?.count ?? 0
            let rhsCount = byServer[$1]?.count ?? 0
            if lhsCount != rhsCount { return lhsCount < rhsCount }
            let lhsName = byServer[$0]?.first?.serverName.lowercased() ?? ""
            let rhsName = byServer[$1]?.first?.serverName.lowercased() ?? ""
            if lhsName != rhsName { return lhsName < rhsName }
            return $0.uuidString < $1.uuidString
        }

        var ordered: [ActionToolSpec] = []
        var index = 0
        while ordered.count < tools.count {
            var added = false
            for id in serverOrder {
                guard let list = byServer[id], index < list.count else { continue }
                ordered.append(list[index])
                added = true
            }
            if !added { break }
            index += 1
        }
        return ordered
    }

    static func relevanceScore(of tool: ActionToolSpec, task: String) -> Int {
        relevanceScore(of: tool, intent: HeuristicIntentExtractor.intent(for: task))
    }

    static func relevanceScore(of tool: ActionToolSpec, intent: ActionIntent) -> Int {
        let name = tool.toolName.lowercased()
        let description = tool.description.lowercased()
        let server = tool.serverName.lowercased()
        var score = preferenceIndex(of: tool, intent: intent) == Int.max ? 0 : 10
        if intent.scope == .activeTab, ActionToolFilter.isChromeAutomation(tool.serverName) { score += 100 }
        for term in intent.routingTerms {
            if name == term {
                score += 6
            } else if name.contains(term) {
                score += 4
            }
            if server.contains(term) {
                score += 3
            }
            if !descriptionStopwords.contains(term), description.contains(term) {
                score += 1
            }
        }
        return score
    }

    private static let descriptionStopwords: Set<String> = [
        "open", "and", "com", "the", "app", "browser", "please", "for", "with", "this", "that", "then", "from", "into"
    ]

    private static func preferenceIndex(of tool: ActionToolSpec, intent: ActionIntent) -> Int {
        if intent.scope == .activeTab, !ActionToolFilter.isChromeAutomation(tool.serverName) { return Int.max }
        let preferred: [String]
        switch intent.action {
        case .openApp: preferred = ["launch_app", "bring_to_front", "list_apps", "run_process", "run_command"]
        case .openURL: preferred = ["new_page", "navigate_page", "list_pages", "launch_app", "browser_navigate", "get_browser_state"]
        case .webSearch: preferred = ["new_page", "navigate_page", "list_pages", "browser_navigate", "get_browser_state"]
        case .navigate: preferred = ["list_pages", "evaluate_script", "navigate_page", "take_snapshot", "select_page", "click"]
        case .find: preferred = ["list_pages", "evaluate_script", "take_snapshot", "navigate_page", "click", "select_page"]
        case .switchApp: preferred = ["bring_to_front", "list_windows", "list_apps"]
        case .click: preferred = ["get_window_state", "click", "list_windows"]
        case .typeText: preferred = ["get_window_state", "set_value", "type_text", "list_windows"]
        case .pressKey: preferred = ["press_key", "hotkey", "get_window_state", "list_windows"]
        case .scroll: preferred = ["scroll", "get_window_state", "list_windows"]
        case .readScreen: preferred = ["get_window_state", "take_snapshot", "list_windows"]
        case .other: preferred = []
        }
        return preferred.firstIndex(of: tool.toolName.lowercased()) ?? Int.max
    }
}

enum ActionArgumentNormalizer {
    static func normalize(argumentsJSON: String, schemaJSON: String) -> String {
        guard !argumentsJSON.isEmpty,
              let argumentData = argumentsJSON.data(using: .utf8),
              var arguments = try? JSONSerialization.jsonObject(with: argumentData) as? [String: Any],
              let schemaData = schemaJSON.data(using: .utf8),
              let schema = try? JSONSerialization.jsonObject(with: schemaData) as? [String: Any] else {
            return argumentsJSON
        }

        let urlKeys = urlPropertyNames(in: schema)
        guard !urlKeys.isEmpty else { return argumentsJSON }

        var changed = false
        for key in urlKeys {
            guard let value = arguments[key] as? String, let normalized = normalizedURL(value) else { continue }
            arguments[key] = normalized
            changed = true
        }
        guard changed,
              JSONSerialization.isValidJSONObject(arguments),
              let output = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]),
              let string = String(data: output, encoding: .utf8) else {
            return argumentsJSON
        }
        return string
    }

    static func applyingObservationDefaults(argumentsJSON: String, schemaJSON: String) -> String {
        guard let schemaData = schemaJSON.data(using: .utf8),
              let schema = try? JSONSerialization.jsonObject(with: schemaData) as? [String: Any],
              let properties = schema["properties"] as? [String: Any],
              properties["include_screenshot"] != nil else { return argumentsJSON }
        var arguments: [String: Any] = [:]
        if !argumentsJSON.isEmpty, let data = argumentsJSON.data(using: .utf8) {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return argumentsJSON }
            arguments = object
        }
        guard arguments["include_screenshot"] == nil else { return argumentsJSON }
        arguments["include_screenshot"] = false
        guard JSONSerialization.isValidJSONObject(arguments),
              let output = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]),
              let string = String(data: output, encoding: .utf8) else { return argumentsJSON }
        return string
    }

    static func urlPropertyNames(in schema: [String: Any]) -> Set<String> {
        guard let properties = schema["properties"] as? [String: Any] else { return [] }
        return Set(properties.keys.filter(isURLPropertyName))
    }

    static func isURLPropertyName(_ name: String) -> Bool {
        let normalized = name.lowercased().filter { $0.isLetter || $0.isNumber }
        return normalized == "url" || normalized == "uri" || normalized == "href"
            || normalized == "link" || normalized.hasSuffix("url") || normalized.hasSuffix("uri")
    }

    static func normalizedURL(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(" "),
              !trimmed.contains("://"),
              !trimmed.hasPrefix("//"),
              !trimmed.hasPrefix("/"),
              !trimmed.hasPrefix("~"),
              !trimmed.hasPrefix("."),
              !hasScheme(trimmed) else {
            return nil
        }

        let host = String(trimmed.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
        guard host.contains("."), !host.contains(":"), !host.hasPrefix("."), !host.hasSuffix(".") else {
            return nil
        }
        let labels = host.split(separator: ".")
        guard let topLevel = labels.last, topLevel.count >= 2, topLevel.allSatisfy(\.isLetter) else {
            return nil
        }
        return "https://\(trimmed)"
    }

    private static func hasScheme(_ value: String) -> Bool {
        guard let colon = value.firstIndex(of: ":") else { return false }
        let scheme = value[value.startIndex..<colon]
        guard let first = scheme.first, first.isLetter else { return false }
        return scheme.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }
    }
}

enum ActionToolFilter {
    static func filtering(_ tools: [ActionToolSpec], task: String) -> [ActionToolSpec] {
        filtering(tools, intent: HeuristicIntentExtractor.intent(for: task))
    }

    /// Server housekeeping that a spoken command never needs. Offering these only invites the
    /// model to call them (it asked Cua Driver to prompt for permissions mid-command).
    static let housekeepingNames: Set<String> = [
        "check_permissions", "check_for_update", "get_cursor_position", "get_screen_size", "health_report",
        "get_config", "set_config", "install_ffmpeg", "start_recording", "stop_recording", "get_recording_state",
        "replay_trajectory", "get_agent_cursor_state", "set_agent_cursor_enabled", "set_agent_cursor_motion",
        "set_agent_cursor_theme", "start_session", "end_session", "get_session", "get_session_state", "list_sessions",
        "escalate_session", "move_cursor", "clipboard_write", "kill_app", "zoom"
    ]

    static func filtering(_ tools: [ActionToolSpec], intent: ActionIntent) -> [ActionToolSpec] {
        let tools = tools.filter { !housekeepingNames.contains($0.toolName.lowercased()) }
        if intent.scope == .activeTab {
            guard ActionIntentPolicy.targetsActiveChromeTab(intent) else { return [] }
            let chrome = tools.filter { isChromeAutomation($0.serverName) }
            guard Set(chrome.map(\.serverID)).count == 1 else { return [] }
            let names = Set(chrome.map(\.toolName))
            guard names.contains("list_pages"), names.contains(intent.action == .navigate ? "navigate_page" : "take_snapshot") else { return [] }
            return chrome.filter { $0.toolName != "new_page" }.map { spec in
                var observed = spec
                observed.requiresFreshObservation = ["list_pages", "take_snapshot"].contains(spec.toolName)
                return observed
            }
        }
        guard ActionIntentPolicy.excludesChromeAutomation(intent) else { return tools }
        let filtered = tools.filter { !isChromeAutomation($0.serverName) }
        return filtered.isEmpty ? tools : filtered
    }

    static func namesNonChromeBrowser(_ task: String) -> Bool {
        ActionIntentPolicy.excludesChromeAutomation(HeuristicIntentExtractor.intent(for: task))
    }

    static func isChromeAutomation(_ serverName: String) -> Bool {
        let normalized = serverName.lowercased().replacingOccurrences(of: "_", with: "-")
        return normalized.contains("chrome-devtools")
    }
}

@MainActor
protocol ActionPlanning: AnyObject {
    func run(
        task: String,
        tools: [ActionToolSpec],
        maxSteps: Int,
        execute: @escaping @Sendable (ActionToolSpec, String) async throws -> String,
        onEvent: @escaping @Sendable (ActionPlanEvent) -> Void
    ) async throws -> String
}

struct ActionPlanStep: Equatable, Sendable {
    let task: String
    let context: ActionPlanContext

    init(task: String, context: ActionPlanContext? = nil) {
        self.task = task
        self.context = context ?? ActionPlanContext(command: task)
    }
}

@MainActor
protocol ContextualActionPlanning: ActionPlanning {
    func run(
        step: ActionPlanStep,
        tools: [ActionToolSpec],
        maxSteps: Int,
        execute: @escaping @Sendable (ActionToolSpec, String) async throws -> String,
        onEvent: @escaping @Sendable (ActionPlanEvent) -> Void
    ) async throws -> String
}

extension ActionPlanning {
    func run(
        step: ActionPlanStep,
        tools: [ActionToolSpec],
        maxSteps: Int,
        execute: @escaping @Sendable (ActionToolSpec, String) async throws -> String,
        onEvent: @escaping @Sendable (ActionPlanEvent) -> Void
    ) async throws -> String {
        if let contextual = self as? any ContextualActionPlanning, !step.context.isEmpty {
            return try await contextual.run(step: step, tools: tools, maxSteps: maxSteps, execute: execute, onEvent: onEvent)
        }
        return try await run(task: step.task, tools: tools, maxSteps: maxSteps, execute: execute, onEvent: onEvent)
    }
}

@MainActor
protocol ActionRouting: AnyObject, Sendable {
    func prepareTools() async throws -> [ActionToolSpec]
    func execute(spec: ActionToolSpec, argumentsJSON: String) async throws -> String
    func requestPlanApproval(_ plan: ActionPlanApprovalRequest) async -> ActionPlanApprovalDecision
    func cancelPendingApprovals()
}

extension ActionRouting {
    func requestPlanApproval(_ plan: ActionPlanApprovalRequest) async -> ActionPlanApprovalDecision { .stepByStep }
    func cancelPendingApprovals() {}
}

enum ActionResultText {
    static let defaultLimit = 4_000
    static let modelLimit = 800

    static func truncate(_ text: String, limit: Int = defaultLimit) -> String {
        guard limit > 0, text.count > limit else { return text }
        let omitted = text.count - limit
        return "\(text.prefix(limit))\n…[\(omitted) characters omitted]"
    }
}

enum ActionRedactor {
    static func redact(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return redactText(json)
        }
        let redacted = redact(object)
        guard JSONSerialization.isValidJSONObject(redacted),
              let output = try? JSONSerialization.data(withJSONObject: redacted, options: [.sortedKeys]),
              let string = String(data: output, encoding: .utf8) else {
            return redactText(json)
        }
        return string
    }

    private static func redact(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, nested) in dictionary {
                result[key] = isSensitive(key) ? "***" : redact(nested)
            }
            return result
        }
        if let array = value as? [Any] {
            return array.map(redact)
        }
        if let text = value as? String { return redactText(text) }
        return value
    }

    private static func isSensitive(_ key: String) -> Bool {
        ["text", "value", "label", "target", "description"].contains(key.lowercased())
            || SensitiveDataPolicy.isSensitiveKey(key)
    }

    private static let secretPatterns: [NSRegularExpression] = [
        #"(?i)(bearer\s+)[A-Za-z0-9._~+/\-]+=*"#,
        #"(?i)(["']?(?:api[_-]?key|token|secret|password|passwd|authorization)["']?\s*[:=]\s*)(?:"(?:\\.|[^"\\])*(?:"|$)|'(?:\\.|[^'\\])*(?:'|$)|“[^”]*(?:”|$)|‘[^’]*(?:’|$)|[^\s,;&"}]+)"#
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    static func redactText(_ text: String) -> String {
        var result = text
        for regex in secretPatterns {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "$1***")
        }
        return result
    }
}
