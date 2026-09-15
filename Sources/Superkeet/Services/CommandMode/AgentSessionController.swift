import Foundation
import os.log

#if canImport(FoundationModels)
import FoundationModels
#endif

private let agentLog = Logger(subsystem: "com.superkeet.app", category: "AgentSession")

@MainActor
final class AgentSessionController: ObservableObject {
    static let shared = AgentSessionController()

    enum Phase: Equatable {
        case idle
        case planning
        case running
        case finished(String)
        case failed(String)
        case cancelled

        var isActive: Bool {
            self == .planning || self == .running
        }

        /// Whether the HUD should be on screen for this phase: while the session
        /// is working, and once it has an outcome.
        var showsHUD: Bool {
            isActive || isOutcome
        }

        /// Whether the HUD should surface the result of a finished session.
        var isOutcome: Bool {
            switch self {
            case .finished, .failed: return true
            default: return false
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var commandText: String = ""
    @Published private(set) var liveMessage: String = ""
    @Published private(set) var activityLog: [String] = []
    @Published private(set) var stepIndex: Int = 0
    @Published private(set) var stepTotal: Int = 0

    private let settings: AppSettings
    private let router: any ActionRouting
    private let plannerFactory: @MainActor () -> (any ActionPlanning)?
    private var runTask: Task<Void, Never>?
    private var reportedRuntimeIssue: String?
    private var toolResultCache: [String: String] = [:]

    init(
        settings: AppSettings? = nil,
        router: (any ActionRouting)? = nil,
        plannerFactory: (@MainActor () -> (any ActionPlanning)?)? = nil
    ) {
        self.settings = settings ?? .shared
        self.router = router ?? ActionToolRouter.shared
        self.plannerFactory = plannerFactory ?? { AgentSessionController.makePlanner() }
    }

    @MainActor
    static func makePlanner() -> (any ActionPlanning)? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), AppleIntelligenceAvailability.current.isAvailable {
            return FoundationModelActionPlanner()
        }
        #endif
        return nil
    }

    func handleCommand(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !phase.isActive else { return }
        commandText = trimmed
        liveMessage = ""
        activityLog = []
        stepIndex = 0
        stepTotal = 0
        toolResultCache.removeAll()
        phase = .planning
        settings.isActionSessionActive = true
        settings.actionStatusText = "Thinking…"
        runTask?.cancel()
        runTask = Task { [weak self] in
            await self?.run(trimmed)
        }
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
        ActionApprovalController.shared.cancelPending()
        finish(.cancelled)
    }

    func reset() {
        guard !phase.isActive else { return }
        phase = .idle
        commandText = ""
        liveMessage = ""
        activityLog = []
        stepIndex = 0
        stepTotal = 0
        if let reported = reportedRuntimeIssue, settings.runtimeIssue == reported {
            settings.runtimeIssue = nil
        }
        reportedRuntimeIssue = nil
    }

    private func run(_ task: String) async {
        do {
            guard let planner = plannerFactory() else {
                throw ActionExecutionError.unavailable
            }
            let tools = try await router.prepareTools()
            guard !tools.isEmpty else {
                throw ActionExecutionError.noTools
            }

            let budget = StepBudget(limit: max(1, settings.actionMaxSteps))
            stepTotal = budget.limit
            let execute: @Sendable (ActionToolSpec, String) async throws -> String = { [weak self] spec, arguments in
                guard let self else { throw ActionExecutionError.cancelled }
                return try await self.performStep(spec: spec, argumentsJSON: arguments, budget: budget)
            }

            phase = .planning
            let output = try await planner.run(
                task: task,
                tools: tools,
                maxSteps: budget.limit,
                execute: execute
            ) { [weak self] event in
                Task { @MainActor in self?.apply(event) }
            }

            if Task.isCancelled {
                finish(.cancelled)
            } else {
                finish(.finished(output.isEmpty ? "Done." : output))
            }
        } catch {
            if Task.isCancelled || isCancellation(error) {
                finish(.cancelled)
            } else {
                finish(.failed(userFacingMessage(for: error)))
            }
        }
    }

    @MainActor
    private func performStep(spec: ActionToolSpec, argumentsJSON: String, budget: StepBudget) async throws -> String {
        guard !Task.isCancelled else { throw ActionExecutionError.cancelled }

        let cacheKey = "\(spec.id)|\(argumentsJSON)"
        if let cached = toolResultCache[cacheKey] {
            apply(.toolReused(spec))
            return cached
        }

        guard budget.consume() else { throw ActionExecutionError.stepBudgetExceeded }
        stepIndex = budget.used
        apply(.toolStarted(spec))
        do {
            let output = try await router.execute(spec: spec, argumentsJSON: argumentsJSON)
            toolResultCache[cacheKey] = output
            apply(.toolFinished(spec, output))
            return output
        } catch let error as ActionExecutionError {
            if case .approvalDenied = error {
                apply(.toolDenied(spec))
            } else {
                apply(.toolFailed(spec, error.localizedDescription))
            }
            throw error
        } catch {
            apply(.toolFailed(spec, error.localizedDescription))
            throw error
        }
    }

    private func apply(_ event: ActionPlanEvent) {
        switch event {
        case .planning:
            phase = .planning
            settings.actionStatusText = "Thinking…"
        case .message(let text):
            liveMessage = text
        case .toolStarted(let spec):
            phase = .running
            activityLog.append("Running \(spec.displayName)…")
            settings.actionStatusText = "Running \(spec.displayName)…"
        case .toolFinished(let spec, _):
            activityLog.append("Finished \(spec.displayName)")
            settings.actionStatusText = "Working…"
        case .toolFailed(let spec, let message):
            activityLog.append("Failed \(spec.displayName): \(message)")
            settings.actionStatusText = "Failed \(spec.displayName)"
        case .toolDenied(let spec):
            activityLog.append("Denied \(spec.displayName)")
            settings.actionStatusText = "Denied \(spec.displayName)"
        case .toolReused(let spec):
            activityLog.append("Reused \(spec.displayName)")
            settings.actionStatusText = "Working…"
        }
    }

    private func finish(_ phase: Phase) {
        self.phase = phase
        settings.isActionSessionActive = false
        settings.actionStatusText = ""
        if case .failed(let message) = phase {
            let issue = "Actions Mode: \(message)"
            settings.runtimeIssue = issue
            reportedRuntimeIssue = issue
        }
        runTask = nil
        agentLog.info("Action session finished: \(String(describing: phase), privacy: .public)")
    }

    private func userFacingMessage(for error: Error) -> String {
        if let actionError = error as? ActionExecutionError {
            return actionError.localizedDescription
        }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if let toolError = error as? LanguageModelSession.ToolCallError {
                return toolError.underlyingError.localizedDescription
            }
            if let generationError = error as? LanguageModelSession.GenerationError,
               case .exceededContextWindowSize = generationError {
                return "That request needed more context than the on-device model allows. Try a narrower request, or turn off extra MCP servers."
            }
        }
        #endif
        return error.localizedDescription
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let actionError = error as? ActionExecutionError, actionError == .cancelled { return true }
        return false
    }

    final class StepBudget: @unchecked Sendable {
        let limit: Int
        private(set) var used = 0

        init(limit: Int) {
            self.limit = limit
        }

        func consume() -> Bool {
            guard used < limit else { return false }
            used += 1
            return true
        }
    }
}
