import Foundation
import os.log

#if canImport(FoundationModels)
import FoundationModels

private let plannerLog = Logger(subsystem: "com.superkeet.app", category: "ActionPlanner")

@available(macOS 26.0, *)
final class FoundationModelActionPlanner: ContextualActionPlanning {
    private static let reservedContextTokens = 2_400
    private static let minimumToolBudgetTokens = 400
    private static let maximumOverflowRetries = 2
    static let maximumContinuations = 1

    private static let baseInstructions = """
    You are Superkeet, an on-device assistant that carries out the user's spoken request by calling the provided tools.
    Call a tool only when it is needed to complete the request, and prefer read-only tools when possible.
    Always give URLs a scheme such as `https://`; never pass a bare domain like `youtube.com`.
    Use the app or browser the user names. Do not drive a different browser's automation tools instead.
    Never repeat a mutating tool with the same arguments; reuse its result. Reuse read-only results unless fresh page state is required.
    Do not invent tool results. When the request is complete, reply with a short, plain-language summary.
    Only report that something happened if a tool result actually shows it happened.
    If none of the available tools can accomplish the request, say so plainly instead of calling an unrelated tool.
    """

    static func instructions(
        for tools: [ActionToolSpec], intent: ActionIntent? = nil, context: ActionPlanContext? = nil, task: String = ""
    ) -> String {
        let names = Set(tools.map(\.toolName))
        var text = baseInstructions
        if names.contains("open_app") {
            text += "\nTo open an app, use open_app with its installed app name."
        }
        if names.contains("open_url") {
            text += "\nTo open a URL, use open_url. Set browser to the browser the user names; omit it only for the default browser."
        }
        if names.contains("press_shortcut") {
            text += "\nTo use a keyboard shortcut in an app that is already open, use press_shortcut with the app name and keys such as [\"cmd\",\"n\"] for New, [\"cmd\",\"s\"] for Save, or [\"cmd\",\"w\"] to close. Prefer it over clicking through menus."
        }
        if let context, !context.isEmpty {
            let progress = context.instructions(for: task)
            if !progress.isEmpty { text += "\n\n" + progress }
        }
        if !names.isDisjoint(with: ["run_process", "run_command"]) {
            text += "\nIf a native open tool cannot handle the request, the shell tool can run `open -a \"App Name\"` or `open -a \"Browser Name\" \"https://example.com\"`."
        }
        if intent?.scope == .activeTab {
            text += """

            This request targets an existing Chrome tab. Call list_pages first. Use only returned pageId values; never invent IDs.
            The MCP [selected] marker is its tool context, not proof of the user's active tab. If multiple pages exist, verify focus using evaluate_script with () => ({focused: document.hasFocus(), url: location.href}) on observed pageIds. Do not bring a page to the front to manufacture focus.
            Use the uniquely focused page, or the only available page. If the active tab cannot be identified from the available results, explain that and stop.
            Keep that pageId for navigate_page, take_snapshot and click. If a tool has no pageId parameter, use select_page with the observed ID and bringToFront:false to set its context first.
            Navigate in place with navigate_page; get click uids from take_snapshot. Refresh page lists and snapshots after page changes. Repeating these read-only observations is allowed; never repeat a mutation.
            """
        }
        if let intent, intent.routingTerms.isSuperset(of: ["cloudflare", "dns"]),
           !names.isDisjoint(with: ["navigate_page", "open_url", "browser_navigate"]) {
            text += """

            For Cloudflare DNS navigation, use `https://dash.cloudflare.com/?to=/:account/<zone>/dns/records`. Replace <zone> only with the exact domain supplied by the user or verified in tool results; retain :account. If the zone is unclear, ask rather than inventing or correcting a domain. Do not construct /dns URLs on the zone's website or www.cloudflare.com. Navigation alone does not prove that DNS records were read or changed.
            """
        }
        return text
    }

    func run(
        task: String,
        tools: [ActionToolSpec],
        maxSteps: Int,
        execute: @escaping @Sendable (ActionToolSpec, String) async throws -> String,
        onEvent: @escaping @Sendable (ActionPlanEvent) -> Void
    ) async throws -> String {
        try await run(step: ActionPlanStep(task: task), tools: tools, maxSteps: maxSteps, execute: execute, onEvent: onEvent)
    }

    func run(
        step: ActionPlanStep,
        tools: [ActionToolSpec],
        maxSteps: Int,
        execute: @escaping @Sendable (ActionToolSpec, String) async throws -> String,
        onEvent: @escaping @Sendable (ActionPlanEvent) -> Void
    ) async throws -> String {
        let task = step.task
        let context = step.context
        let intent = HeuristicIntentExtractor.intent(for: task)
        let recorder = ToolExecutionRecorder()
        let recordingExecute: @Sendable (ActionToolSpec, String) async throws -> String = { spec, arguments in
            await recorder.markExecuted()
            do {
                let result = try await execute(spec, arguments)
                await recorder.record(toolName: spec.toolName, argumentsJSON: arguments, result: result)
                return result
            } catch {
                await recorder.recordFailure(toolName: spec.toolName, argumentsJSON: arguments,
                                             message: ActionErrorHandling.userFacingMessage(for: error))
                throw error
            }
        }
        let candidates = Self.toolBridges(from: tools, intent: intent, execute: recordingExecute)
        guard !candidates.isEmpty else {
            throw intent.scope == .activeTab ? ActionExecutionError.activeChromeTabUnavailable : .noTools
        }

        var budget = toolBudgetTokens()
        var attempt = 0
        var continuations = 0
        var progress: ActionProgressSummary?

        while true {
            let selected = await selectTools(from: candidates, budget: budget)
            guard !selected.isEmpty else { throw ActionExecutionError.noTools }

            plannerLog.info(
                "Planning with \(selected.count)/\(candidates.count) tools (budget \(budget) tokens)"
            )

            onEvent(.planning)
            do {
                var instructions = Self.instructions(for: selected.map(\.spec), intent: intent, context: context, task: task)
                if let progress { instructions += "\n\n" + progress.instructions() }
                let session = LanguageModelSession(tools: selected.map { $0 as any Tool }, instructions: instructions)
                var latest = ""
                for try await snapshot in session.streamResponse(to: task) {
                    latest = snapshot.content
                    onEvent(.message(latest))
                }
                return latest
            } catch let error as LanguageModelSession.GenerationError {
                guard case .exceededContextWindowSize = error else { throw error }
                if await !recorder.hasExecuted {
                    guard attempt < Self.maximumOverflowRetries, selected.count > 1 else { throw error }
                    attempt += 1
                    budget = max(Self.minimumToolBudgetTokens, budget * 3 / 5)
                    plannerLog.info("Context window exceeded; retrying with a \(budget)-token tool budget")
                    continue
                }
                guard continuations < Self.maximumContinuations else { throw error }
                continuations += 1
                progress = await recorder.progress
                plannerLog.info("Context window exceeded after tool calls; continuing with a condensed transcript")
                onEvent(.message("Condensing progress and continuing…"))
                continue
            }
        }
    }

    static func toolBridges(
        from tools: [ActionToolSpec], intent: ActionIntent,
        execute: @escaping @Sendable (ActionToolSpec, String) async throws -> String
    ) -> [MCPToolBridge] {
        let available = ActionToolFilter.filtering(tools, intent: intent)
        let native = available.filter { $0.serverID == NativeOpenAction.serverID }
        let external = available.filter { $0.serverID != NativeOpenAction.serverID }
        let prioritized = native + ActionLimits.prioritizedTools(external, intent: intent)
        return Array(prioritized.compactMap { MCPToolBridge(spec: $0, execute: execute) }.prefix(ActionLimits.maximumToolsPerAction))
    }

    private func toolBudgetTokens() -> Int {
        let contextSize = SystemLanguageModel.default.contextSize
        return max(Self.minimumToolBudgetTokens, contextSize - Self.reservedContextTokens)
    }

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
            let cost = candidate.estimatedTokenCost
            if selected.isEmpty || used + cost <= budget {
                selected.append(candidate)
                used += cost
            }
        }
        return selected
    }

    private actor ToolExecutionRecorder {
        private var executed = false
        private(set) var progress = ActionProgressSummary()

        var hasExecuted: Bool { executed }

        func markExecuted() {
            executed = true
        }

        func record(toolName: String, argumentsJSON: String, result: String) {
            progress.record(toolName: toolName, argumentsJSON: argumentsJSON, result: result)
        }

        func recordFailure(toolName: String, argumentsJSON: String, message: String) {
            progress.recordFailure(toolName: toolName, argumentsJSON: argumentsJSON, message: message)
        }
    }
}

#endif
