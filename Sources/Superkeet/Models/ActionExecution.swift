import Foundation

struct ActionToolSpec: Identifiable, Equatable {
    let serverID: UUID
    let serverName: String
    let toolName: String
    let displayName: String
    let description: String
    let risk: ActionToolRisk
    let inputSchemaJSON: String

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

struct ActionApprovalRequest: Identifiable, Equatable {
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
    case approvalDenied(String)
    case stepBudgetExceeded
    case timedOut
    case cancelled
    case argumentsTooLarge

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Actions Mode needs macOS 26 with Apple Intelligence enabled."
        case .noTools:
            return "No MCP tools are available. Add and enable an MCP server in Settings > Actions."
        case .approvalDenied(let tool):
            return "The action was not approved, so '\(tool)' did not run."
        case .stepBudgetExceeded:
            return "The action used too many steps and was stopped."
        case .timedOut:
            return "The action took too long and was stopped."
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

    /// Approximate token cost of a tool definition when the exact framework
    /// counter is unavailable (macOS 26.0–26.3). The bridge drops schema
    /// descriptions and titles, so they are pruned first; measurements put the
    /// framework's real cost at roughly one token per two pruned characters,
    /// and this rounds up to stay safely inside the context window.
    static func estimatedTokenCost(of tool: ActionToolSpec) -> Int {
        tool.toolName.count + tool.description.count + prunedSchemaCharacters(tool.inputSchemaJSON) / 2 + 40
    }

    private static let prunedSchemaKeys: Set<String> = [
        "description", "title", "$schema", "$comment", "examples", "default",
        "additionalProperties", "format", "pattern", "deprecated", "readOnly", "writeOnly"
    ]

    private static func prunedSchemaCharacters(_ json: String) -> Int {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let pruned = try? JSONSerialization.data(withJSONObject: pruneSchema(object)) else {
            return json.count * 2
        }
        return pruned.count
    }

    private static func pruneSchema(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, nested) in dictionary where !prunedSchemaKeys.contains(key) {
                result[key] = pruneSchema(nested)
            }
            return result
        }
        if let array = value as? [Any] {
            return array.map(pruneSchema)
        }
        return value
    }

    /// Orders tools so the most relevant come first, while still round-robining
    /// across enabled servers. This keeps every server represented even when the
    /// context window can only hold a subset of the available tools.
    static func prioritizedTools(_ tools: [ActionToolSpec], task: String) -> [ActionToolSpec] {
        let taskTerms = terms(in: task)

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
                let lhs = relevanceScore(of: $0, terms: taskTerms)
                let rhs = relevanceScore(of: $1, terms: taskTerms)
                if lhs != rhs { return lhs > rhs }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        }
        serverOrder.sort {
            let lhs = byServer[$0]?.first.map { relevanceScore(of: $0, terms: taskTerms) } ?? 0
            let rhs = byServer[$1]?.first.map { relevanceScore(of: $0, terms: taskTerms) } ?? 0
            if lhs != rhs { return lhs > rhs }
            return (byServer[$0]?.count ?? 0) < (byServer[$1]?.count ?? 0)
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
        relevanceScore(of: tool, terms: terms(in: task))
    }

    private static func terms(in task: String) -> Set<String> {
        let words = task.lowercased().split { !$0.isLetter && !$0.isNumber }
        return Set(words.filter { $0.count >= 3 }.map(String.init))
    }

    private static func relevanceScore(of tool: ActionToolSpec, terms: Set<String>) -> Int {
        guard !terms.isEmpty else { return 0 }
        let name = tool.toolName.lowercased()
        let description = tool.description.lowercased()
        let server = tool.serverName.lowercased()
        var score = 0
        for term in terms {
            if name == term {
                score += 6
            } else if name.contains(term) {
                score += 4
            }
            if server.contains(term) {
                score += 3
            }
            if description.contains(term) {
                score += 1
            }
        }
        return score
    }
}

/// Repairs common model mistakes before arguments reach an MCP server. Today it
/// ensures URL-typed arguments carry a scheme, because tools (for example
/// Chrome DevTools) reject bare domains like `youtube.com`.
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

    static func urlPropertyNames(in schema: [String: Any]) -> Set<String> {
        guard let properties = schema["properties"] as? [String: Any] else { return [] }
        return Set(properties.keys.filter(isURLPropertyName))
    }

    static func isURLPropertyName(_ name: String) -> Bool {
        let normalized = name.lowercased().filter { $0.isLetter || $0.isNumber }
        return normalized == "url" || normalized == "uri" || normalized == "href"
            || normalized == "link" || normalized.hasSuffix("url") || normalized.hasSuffix("uri")
    }

    /// Returns the value with an `https://` scheme when it looks like a bare
    /// host, or `nil` when the value is empty, already qualified, or not a URL.
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

/// Keeps the planning tool set consistent with the app the user names. Chrome
/// DevTools drives Chrome/Chromium, so when the user names any other browser it
/// is withheld and the model is forced to open the requested browser instead of
/// silently substituting Chrome.
enum ActionToolFilter {
    static let nonChromeBrowsers: Set<String> = [
        "safari", "helium", "firefox", "edge", "brave", "arc",
        "opera", "vivaldi", "chromium", "dia", "orion", "floorp", "zen"
    ]

    static func filtering(_ tools: [ActionToolSpec], task: String) -> [ActionToolSpec] {
        guard namesNonChromeBrowser(task) else { return tools }
        let filtered = tools.filter { !isChromeAutomation($0.serverName) }
        return filtered.isEmpty ? tools : filtered
    }

    static func namesNonChromeBrowser(_ task: String) -> Bool {
        let tokens = Set(task.lowercased().split { !$0.isLetter }.map(String.init))
        return !tokens.isDisjoint(with: nonChromeBrowsers)
    }

    static func isChromeAutomation(_ serverName: String) -> Bool {
        let normalized = serverName.lowercased().replacingOccurrences(of: "_", with: "-")
        return normalized.contains("chrome-devtools")
    }
}

protocol ActionPlanning: AnyObject {
    func run(
        task: String,
        tools: [ActionToolSpec],
        maxSteps: Int,
        execute: @escaping @Sendable (ActionToolSpec, String) async throws -> String,
        onEvent: @escaping @Sendable (ActionPlanEvent) -> Void
    ) async throws -> String
}

@MainActor
protocol ActionRouting: AnyObject {
    func prepareTools() async throws -> [ActionToolSpec]
    func execute(spec: ActionToolSpec, argumentsJSON: String) async throws -> String
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
        return value
    }

    private static func isSensitive(_ key: String) -> Bool {
        SensitiveDataPolicy.isSensitiveKey(key)
    }

    static func redactText(_ text: String) -> String {
        var result = text
        let patterns = [
            "(?i)(bearer\\s+)[A-Za-z0-9._\\-]+",
            "(?i)((?:api[_-]?key|token|secret|password|authorization)\\s*[:=]\\s*)[^\\s,;\"}]+"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "$1***")
        }
        return result
    }
}
