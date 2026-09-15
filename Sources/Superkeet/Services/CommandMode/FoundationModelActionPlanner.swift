import Foundation
import os.log

#if canImport(FoundationModels)
import FoundationModels

private let plannerLog = Logger(subsystem: "com.superkeet.app", category: "ActionPlanner")

@available(macOS 26.0, *)
enum MCPGenerationSchemaConverter {
    static func schema(fromJSON json: String) -> GenerationSchema? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let root = dynamicSchema(from: object) else {
            return nil
        }
        return try? GenerationSchema(root: root, dependencies: [])
    }

    static func dynamicSchema(from object: [String: Any]) -> DynamicGenerationSchema? {
        let type = object["type"] as? String

        if type == "array" || object["items"] != nil {
            let items = (object["items"] as? [String: Any]) ?? ["type": "string"]
            guard let item = dynamicSchema(from: items) else { return nil }
            return DynamicGenerationSchema(
                arrayOf: item,
                minimumElements: object["minItems"] as? Int,
                maximumElements: object["maxItems"] as? Int
            )
        }

        if let choices = object["enum"] as? [String], !choices.isEmpty {
            return DynamicGenerationSchema(
                name: uniqueName(object["title"] as? String ?? "value"),
                anyOf: choices
            )
        }

        switch type {
        case "string":
            return DynamicGenerationSchema(type: String.self)
        case "integer":
            return DynamicGenerationSchema(type: Int.self)
        case "number":
            return DynamicGenerationSchema(type: Double.self)
        case "boolean":
            return DynamicGenerationSchema(type: Bool.self)
        case "object", .none:
            return objectSchema(from: object)
        default:
            return DynamicGenerationSchema(type: String.self)
        }
    }

    private static func objectSchema(from object: [String: Any]) -> DynamicGenerationSchema {
        let properties = object["properties"] as? [String: Any] ?? [:]
        let required = Set(object["required"] as? [String] ?? [])
        let props: [DynamicGenerationSchema.Property] = properties
            .sorted { $0.key < $1.key }
            .compactMap { key, value in
                guard let sub = value as? [String: Any], let schema = dynamicSchema(from: sub) else { return nil }
                return DynamicGenerationSchema.Property(
                    name: key,
                    schema: schema,
                    isOptional: !required.contains(key)
                )
            }
        return DynamicGenerationSchema(
            name: uniqueName(object["title"] as? String ?? "parameters"),
            properties: props
        )
    }

    private static func uniqueName(_ raw: String) -> String {
        let sanitized = raw.map { character -> Character in
            character.isLetter || character.isNumber || character == "_" ? character : "_"
        }
        let base = sanitized.isEmpty ? "value" : String(sanitized)
        return "\(base)_\(UUID().uuidString.prefix(8))"
    }
}

@available(macOS 26.0, *)
struct MCPToolBridge: Tool, CustomStringConvertible {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let spec: ActionToolSpec
    let execute: @Sendable (ActionToolSpec, String) async throws -> String

    var name: String { spec.toolName }

    var description: String {
        let base = spec.description.isEmpty ? spec.displayName : spec.description
        let singleLine = base.replacingOccurrences(of: "\n", with: " ")
        return singleLine.count > 140 ? String(singleLine.prefix(140)) : singleLine
    }

    var parameters: GenerationSchema {
        MCPGenerationSchemaConverter.schema(fromJSON: spec.inputSchemaJSON)
            ?? MCPGenerationSchemaConverter.dynamicSchema(from: [:])
                .flatMap { try? GenerationSchema(root: $0, dependencies: []) }
            ?? String.generationSchema
    }

    func call(arguments: GeneratedContent) async throws -> String {
        try await execute(spec, arguments.jsonString)
    }
}

@available(macOS 26.0, *)
final class FoundationModelActionPlanner: ActionPlanning {
    /// Context the model needs to keep free for instructions, the spoken task,
    /// streamed replies, and tool results. Tools are only allowed to use what is
    /// left of `SystemLanguageModel.default.contextSize`.
    private static let reservedContextTokens = 2_400
    private static let minimumToolBudgetTokens = 400
    private static let maximumOverflowRetries = 2

    private static let instructions = """
    You are Superkeet, an on-device assistant that carries out the user's spoken request by calling the provided tools.
    Call a tool only when it is needed to complete the request, and prefer read-only tools when possible.
    To open a macOS app, run the command `open -a "App Name"` (for example, `open -a Helium`).
    To open a URL in the browser the user names, run the command `open -a "Browser Name" "https://example.com"`.
    Always give URLs a scheme such as `https://`; never pass a bare domain like `youtube.com`.
    Use the app or browser the user names. Do not drive a different browser's automation tools instead.
    Never call the same tool with the same arguments more than once; reuse the result you already received.
    Do not invent tool results. When the request is complete, reply with a short, plain-language summary.
    Only report that something happened if a tool result actually shows it happened.
    If none of the available tools can accomplish the request, say so plainly instead of calling an unrelated tool.
    """

    func run(
        task: String,
        tools: [ActionToolSpec],
        maxSteps: Int,
        execute: @escaping @Sendable (ActionToolSpec, String) async throws -> String,
        onEvent: @escaping @Sendable (ActionPlanEvent) -> Void
    ) async throws -> String {
        let available = ActionToolFilter.filtering(ActionLimits.limitedTools(tools), task: task)
        let prioritized = ActionLimits.prioritizedTools(available, task: task)
            .filter { MCPGenerationSchemaConverter.schema(fromJSON: $0.inputSchemaJSON) != nil }
        guard !prioritized.isEmpty else { throw ActionExecutionError.noTools }

        let recorder = ToolExecutionRecorder()
        let recordingExecute: @Sendable (ActionToolSpec, String) async throws -> String = { spec, arguments in
            await recorder.markExecuted()
            return try await execute(spec, arguments)
        }
        let candidates = prioritized.map { MCPToolBridge(spec: $0, execute: recordingExecute) }

        var budget = toolBudgetTokens()
        var attempt = 0

        while true {
            let selected = await selectTools(from: candidates, budget: budget)
            guard !selected.isEmpty else { throw ActionExecutionError.noTools }

            plannerLog.info(
                "Planning with \(selected.count)/\(candidates.count) tools (budget \(budget) tokens)"
            )

            onEvent(.planning)
            do {
                let session = LanguageModelSession(
                    tools: selected.map { $0 as any Tool },
                    instructions: Self.instructions
                )
                var latest = ""
                for try await snapshot in session.streamResponse(to: task) {
                    latest = snapshot.content
                    onEvent(.message(latest))
                }
                return latest
            } catch let error as LanguageModelSession.GenerationError {
                let canRetry = await !recorder.hasExecuted
                    && attempt < Self.maximumOverflowRetries
                    && selected.count > 1
                if case .exceededContextWindowSize = error, canRetry {
                    attempt += 1
                    budget = max(Self.minimumToolBudgetTokens, budget * 3 / 5)
                    plannerLog.info("Context window exceeded; retrying with a \(budget)-token tool budget")
                    continue
                }
                throw error
            }
        }
    }

    private func toolBudgetTokens() -> Int {
        let contextSize = SystemLanguageModel.default.contextSize
        return max(Self.minimumToolBudgetTokens, contextSize - Self.reservedContextTokens)
    }

    /// Greedily keeps tools in priority order while they fit the token budget.
    /// macOS 26.4+ measures the real framework cost; earlier systems fall back to
    /// a conservative character estimate.
    private func selectTools(from candidates: [MCPToolBridge], budget: Int) async -> [MCPToolBridge] {
        if #available(macOS 26.4, *) {
            let model = SystemLanguageModel.default
            var selected: [MCPToolBridge] = []
            for candidate in candidates {
                let projected = selected + [candidate]
                guard let tokens = try? await model.tokenCount(for: projected.map { $0 as any Tool }) else { continue }
                if selected.isEmpty || tokens <= budget {
                    selected = projected
                }
            }
            if !selected.isEmpty { return selected }
        }

        var selected: [MCPToolBridge] = []
        var used = 0
        for candidate in candidates {
            let cost = ActionLimits.estimatedTokenCost(of: candidate.spec)
            if selected.isEmpty || used + cost <= budget {
                selected.append(candidate)
                used += cost
            }
        }
        return selected
    }

    /// Tracks whether any tool has actually run. Once a tool has side effects we
    /// must not silently restart the plan, so overflow retries are disabled.
    private actor ToolExecutionRecorder {
        private var executed = false

        var hasExecuted: Bool { executed }

        func markExecuted() {
            executed = true
        }
    }
}

#endif
