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
    /// Chronological event log, one line per event.
    @Published private(set) var activityLog: [String] = []
    /// The HUD's checklist: rows whose status changes in place.
    @Published private(set) var checklist = ActionChecklist()
    @Published private(set) var stepIndex: Int = 0
    @Published private(set) var stepTotal: Int = 0

    private let settings: AppSettings
    private let router: any ActionRouting
    private let plannerFactory: @MainActor () -> (any ActionPlanning)?
    private let resolveApp: @MainActor (String) -> URL?
    private let isAppRunning: @MainActor (URL) -> Bool
    private var runTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var reportedRuntimeIssue: String?
    private var activeRun: RunContext?

    /// Floor for the whole-command deadline so a misconfigured value cannot
    /// stop every run before its first tool call.
    static let minimumRunDeadlineSeconds = 1

    @MainActor
    private final class RunContext {
        struct CachedResult {
            let output: String
            let mutating: Bool
        }

        let budget: StepBudget
        var toolResults: [String: CachedResult] = [:]
        var cancelOperations: [UUID: @Sendable () -> Void] = [:]
        /// An app opened while the user was still speaking this command.
        var speculative: SpeculativeLaunchResult?
        /// Apps opened by `open_app` steps during this command, in order.
        var openedApps: [NativeLaunchedApp] = []
        /// Words of the step currently running, used to rank observed UI elements.
        var focusTerms: Set<String> = []

        init(limit: Int) { budget = StepBudget(limit: limit) }

        /// A successful state change makes every cached read-only result stale.
        /// Mutation results stay cached so an identical mutation is reused, not repeated.
        func invalidateObservations() {
            toolResults = toolResults.filter { $0.value.mutating }
        }
    }

    init(
        settings: AppSettings? = nil,
        router: (any ActionRouting)? = nil,
        plannerFactory: (@MainActor () -> (any ActionPlanning)?)? = nil,
        resolveApp: (@MainActor (String) -> URL?)? = nil,
        isAppRunning: (@MainActor (URL) -> Bool)? = nil
    ) {
        self.settings = settings ?? .shared
        self.router = router ?? ActionToolRouter.shared
        self.resolveApp = resolveApp ?? { InstalledAppInventory.shared.resolve($0) }
        self.isAppRunning = isAppRunning ?? { InstalledAppInventory.shared.isRunning($0) }
        let resolvedSettings = self.settings
        self.plannerFactory = plannerFactory ?? {
            guard let planner = AgentSessionController.makePlanner() else { return nil }
            return resolvedSettings.nativeGroundingEnabled ? NativeGroundedActionPlanner(fallback: planner) : planner
        }
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

    /// Starts a command. `speculative` is an app launch that began while the
    /// user was still speaking; the run waits for it, reports it, and reuses it
    /// instead of opening the same app again.
    func handleCommand(_ text: String, speculative: SpeculativeLaunch? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, activeRun == nil, !phase.isActive else { return }
        clearReportedRuntimeIssue()
        let run = RunContext(limit: max(1, settings.actionMaxSteps))
        activeRun = run
        commandText = trimmed
        liveMessage = ""
        activityLog = []
        checklist = ActionChecklist()
        stepIndex = 0
        stepTotal = run.budget.limit
        phase = .planning
        settings.isActionSessionActive = true
        settings.actionStatusText = "Thinking…"
        runTask = Task { [weak self] in
            if let speculative { await self?.adopt(speculative, run: run) }
            await self?.run(trimmed, context: run)
        }
        let deadlineSeconds = max(Self.minimumRunDeadlineSeconds, settings.actionRunDeadlineSeconds)
        deadlineTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(deadlineSeconds))
            guard !Task.isCancelled, let self, self.activeRun === run else { return }
            agentLog.info("Action session exceeded its \(deadlineSeconds)s deadline")
            self.finish(.failed(ActionExecutionError.runDeadlineExceeded(seconds: deadlineSeconds).localizedDescription), run: run)
        }
    }

    func cancel() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let run = activeRun else { return }
        finish(.cancelled, run: run)
    }

    func reset() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !phase.isActive else { return }
        phase = .idle
        commandText = ""
        liveMessage = ""
        activityLog = []
        checklist = ActionChecklist()
        stepIndex = 0
        stepTotal = 0
        clearReportedRuntimeIssue()
    }

    private func clearReportedRuntimeIssue() {
        dispatchPrecondition(condition: .onQueue(.main))
        if let reported = reportedRuntimeIssue, settings.runtimeIssue == reported {
            settings.runtimeIssue = nil
        }
        reportedRuntimeIssue = nil
    }

    /// Waits for an early launch to settle and records what happened. The open
    /// request was already dispatched, so this never fails the run; a launch
    /// error only means the command will open the app itself.
    private func adopt(_ speculative: SpeculativeLaunch, run: RunContext) async {
        dispatchPrecondition(condition: .onQueue(.main))
        settings.actionStatusText = "Opening \(speculative.commit.action.app.name)…"
        let result = await speculative.result()
        guard activeRun === run else { return }
        run.speculative = result
        let name = result.appName
        if result.launched != nil {
            let verb = result.action.isActivation ? "Switched to" : "Opened"
            activityLog.append("\(verb) \(name) while you were speaking")
        } else if let failure = result.failure, failure != "cancelled" {
            activityLog.append("Couldn't open \(name) early: \(failure)")
        }
        if result.disagreement {
            activityLog.append("Later speech named a different app; the final command decides")
        }
        checklist.addSpeculative(result)
        settings.actionStatusText = "Thinking…"
    }

    /// State that accumulates while a command's steps run in order.
    @MainActor
    private final class CommandExecution {
        let plan: CommandPlan
        var context: ActionPlanContext
        var outputs: [String] = []
        /// The planner and tool inventory, set up on the first step that needs them.
        var planner: (any ActionPlanning)?
        var tools: [ActionToolSpec] = []
        /// A native open that missed because the app is not installed; reported
        /// if no planner is available to try another way.
        var resolutionFailure: NativeOpenActionError?

        init(plan: CommandPlan) {
            self.plan = plan
            context = ActionPlanContext(command: plan.command)
            context.stepCount = plan.clauses.count
        }
    }

    private func run(_ task: String, context run: RunContext) async {
        do {
            try requireCurrent(run)
            let plan = CommandDecomposer.decompose(task)
            let execution = CommandExecution(plan: plan)
            let intent = HeuristicIntentExtractor.intent(for: task)
            // A recognised single open (including "open X and go to URL") is one
            // native step; it runs before any decomposition so the browser and
            // URL are never split apart.
            if let action = NativeOpenAction.fastPath(for: intent) {
                apply(.planning, run: run)
                do {
                    let output = try await performStep(spec: action.spec, argumentsJSON: action.argumentsJSON(), run: run)
                    finish(.finished(output.isEmpty ? "Done." : output), run: run)
                    return
                } catch let error as NativeOpenActionError {
                    // A missing app is a resolution miss before any OS open call.
                    // Never fall back after denial, cancellation, timeout, or dispatch failure.
                    guard case .appNotFound = error else { throw error }
                    execution.resolutionFailure = error
                }
            }
            try requireCurrent(run)
            if let prior = run.speculative, let launched = prior.launched { execution.context.recordOpened(launched) }

            // A compound command is shown once as a plan card when any of its
            // predictable steps would otherwise ask on its own.
            if plan.isCompound {
                let preview = predictPlan(execution, run: run)
                if preview.needsApproval(under: settings.actionApprovalPolicy) {
                    settings.actionStatusText = "Waiting for approval…"
                    let decision = await ownedPlanApproval(preview, run: run)
                    try requireCurrent(run)
                    switch decision {
                    case .deny: throw ActionExecutionError.planDenied
                    case .approveAll: activityLog.append("Plan approved")
                    case .stepByStep: activityLog.append("Plan will ask for each step")
                    }
                }
            }

            for clause in plan.clauses {
                try requireCurrent(run)
                execution.context.stepNumber = clause.index + 1
                run.focusTerms = clause.focusTerms
                if plan.isCompound {
                    activityLog.append("Step \(execution.context.stepNumber) of \(execution.context.stepCount): \(clause.text)")
                    checklist.addStep(number: execution.context.stepNumber, total: execution.context.stepCount, text: clause.text)
                }
                let output = try await perform(clause, execution: execution, run: run)
                if plan.isCompound {
                    checklist.completeStep(skippedBecause: output == nil ? "Already done while you were speaking" : nil)
                }
                if let output, !output.isEmpty { execution.outputs.append(output) }
                if let output { execution.context.completed.append(.init(clause: clause.text, summary: output)) }
            }

            if Task.isCancelled {
                finish(.cancelled, run: run)
            } else {
                finish(.finished(execution.outputs.isEmpty ? "Done." : execution.outputs.joined(separator: " ")), run: run)
            }
        } catch {
            if Task.isCancelled || ActionErrorHandling.isCancellation(error) {
                finish(.cancelled, run: run)
            } else {
                finish(.failed(ActionErrorHandling.userFacingMessage(for: error)), run: run)
            }
        }
    }

    /// How one step of a compound command will be carried out, decided from the
    /// clause and what earlier steps have done. The same decision drives both
    /// the plan card (with a simulated context) and execution.
    private enum StepRoute {
        /// An app opened while the user was speaking already covers this step.
        case alreadyDone(appName: String)
        /// A built-in open or URL tool.
        case native(NativeOpenAction)
        /// A keyboard-shortcut recipe aimed at a running app.
        case shortcut(NativeAppRecipe, target: String)
        /// The on-device planner.
        case planned
    }

    private func route(for clause: CommandClause, context: ActionPlanContext, plan: CommandPlan, run: RunContext) -> StepRoute {
        if plan.isCompound, let prior = run.speculative, prior.launched != nil,
           CommandDecomposer.clause(clause, isSatisfiedBy: prior, resolveApp: resolveApp) {
            return .alreadyDone(appName: prior.appName)
        }
        if plan.isCompound, var action = NativeOpenAction.fastPath(for: clause.intent) {
            // A URL step with no browser uses the browser this command already opened.
            if case .openURL(let url, nil) = action, let browser = context.currentApp, Self.isBrowser(browser.name) {
                action = .openURL(url: url, browser: browser.name)
            }
            return .native(action)
        }
        if let recipe = NativeAppRecipe.recipe(for: clause.text), let target = recipeTarget(recipe, context: context) {
            return .shortcut(recipe, target: target)
        }
        return .planned
    }

    /// Simulates the command step by step to describe what each one will do,
    /// without running anything. Opens are assumed to succeed so later steps
    /// see the app they will act in.
    private func predictPlan(_ execution: CommandExecution, run: RunContext) -> ActionPlanApprovalRequest {
        var context = execution.context
        var steps: [ActionPlanApprovalRequest.Step] = []
        for clause in execution.plan.clauses {
            context.stepNumber = clause.index + 1
            let number = clause.index + 1
            switch route(for: clause, context: context, plan: execution.plan, run: run) {
            case .alreadyDone(let appName):
                steps.append(.init(number: number, text: clause.text, summary: "Already open: \(appName) (opened while you were speaking)", route: .alreadyDone))
            case .native(let action):
                if case .openApp(let name) = action {
                    let opened = resolveApp(name)?.deletingPathExtension().lastPathComponent ?? name
                    context.recordOpened(NativeLaunchedApp(name: opened, bundleIdentifier: nil, processIdentifier: 0, windowReady: false))
                }
                steps.append(nativeStep(number: number, clause: clause, action: action))
            case .shortcut(let recipe, let target):
                let action = NativeOpenAction.pressShortcut(app: target, shortcut: recipe.shortcut)
                steps.append(nativeStep(number: number, clause: clause, action: action))
            case .planned:
                steps.append(.init(number: number, text: clause.text, summary: "Planned on-device; each tool call asks as usual", route: .planned))
            }
        }
        return ActionPlanApprovalRequest(command: execution.plan.command, steps: steps)
    }

    private func nativeStep(number: Int, clause: CommandClause, action: NativeOpenAction) -> ActionPlanApprovalRequest.Step {
        let arguments = (try? action.argumentsJSON()) ?? "{}"
        let summary = ActionIntentFormatter.summary(toolName: action.toolName, argumentsJSON: arguments) ?? action.spec.displayName
        return .init(number: number, text: clause.text, summary: summary, route: .native(spec: action.spec, argumentsJSON: arguments))
    }

    private func ownedPlanApproval(_ plan: ActionPlanApprovalRequest, run: RunContext) async -> ActionPlanApprovalDecision {
        do {
            return try await ownedOperation(run: run) { [router] in await router.requestPlanApproval(plan) }
        } catch {
            return .deny
        }
    }

    /// Runs one step of the plan: a launch that already happened while the user
    /// was speaking, a native open, a keyboard-shortcut recipe, or the planner.
    /// Returns the step's result, or `nil` when an earlier launch covered it.
    private func perform(_ clause: CommandClause, execution: CommandExecution, run: RunContext) async throws -> String? {
        switch route(for: clause, context: execution.context, plan: execution.plan, run: run) {
        case .alreadyDone(let appName):
            activityLog.append("Already done: \(appName) opened while you were speaking")
            return nil

        case .native(let action):
            apply(.planning, run: run)
            do {
                let output = try await performStep(spec: action.spec, argumentsJSON: action.argumentsJSON(), run: run)
                if let launched = NativeLaunchedApp(summary: output) { execution.context.recordOpened(launched) }
                return output
            } catch let error as NativeOpenActionError {
                // A missing app falls through to the shortcut and planner routes.
                guard case .appNotFound = error else { throw error }
                execution.resolutionFailure = error
                if let recipe = NativeAppRecipe.recipe(for: clause.text), let target = recipeTarget(recipe, context: execution.context) {
                    return try await performShortcut(recipe, target: target, run: run)
                }
            }

        case .shortcut(let recipe, let target):
            return try await performShortcut(recipe, target: target, run: run)

        case .planned:
            break
        }

        // Everything else is planned, with what earlier steps did as context.
        let planner = try await preparePlanner(execution, run: run)
        let execute: @Sendable (ActionToolSpec, String) async throws -> String = { [weak self] spec, arguments in
            guard let self else { throw ActionExecutionError.cancelled }
            return try await self.performStep(spec: spec, argumentsJSON: arguments, run: run)
        }
        apply(.planning, run: run)
        let openedBefore = run.openedApps
        let output = try await planner.run(
            step: ActionPlanStep(task: clause.text, context: execution.context),
            tools: execution.tools, maxSteps: run.budget.limit, execute: execute
        ) { [weak self] event in
            Task { @MainActor in self?.apply(event, run: run) }
        }
        for app in run.openedApps where !openedBefore.contains(app) { execution.context.recordOpened(app) }
        return output
    }

    private func performShortcut(_ recipe: NativeAppRecipe, target: String, run: RunContext) async throws -> String {
        let note = "Using \(recipe.shortcut.displayName) to \(recipe.description) in \(target)"
        activityLog.append(note)
        checklist.addNote(note)
        apply(.planning, run: run)
        let action = NativeOpenAction.pressShortcut(app: target, shortcut: recipe.shortcut)
        return try await performStep(spec: action.spec, argumentsJSON: action.argumentsJSON(), run: run)
    }

    private func preparePlanner(_ execution: CommandExecution, run: RunContext) async throws -> any ActionPlanning {
        if let planner = execution.planner { return planner }
        guard let planner = plannerFactory() else {
            if let failure = execution.resolutionFailure { throw failure }
            throw ActionExecutionError.unavailable
        }
        let prepared = try await prepareExternalTools(for: execution.plan.command, run: run)
        try requireCurrent(run)
        execution.tools = NativeOpenAction.prependingTools(to: prepared)
        execution.planner = planner
        return planner
    }

    /// The app a shortcut recipe should go to: the one the step names, if it is
    /// installed and running, otherwise the app this command most recently
    /// opened. `nil` leaves the step to the planner.
    private func recipeTarget(_ recipe: NativeAppRecipe, context: ActionPlanContext) -> String? {
        switch recipe.target {
        case .named(let name):
            guard let url = resolveApp(name), isAppRunning(url) else { return nil }
            return url.deletingPathExtension().lastPathComponent
        case .current:
            return context.currentApp?.name
        }
    }

    private static func isBrowser(_ appName: String) -> Bool {
        let normalized = AppResolver.normalizedName(appName)
        return ActionIntentPolicy.browsers.contains(normalized)
            || ["google chrome", "microsoft edge"].contains(normalized)
            || normalized.split(separator: " ").contains { ActionIntentPolicy.browsers.contains(String($0)) }
    }

    /// Discovers MCP tools. A missing inventory only blocks requests that need
    /// it: compound open requests continue with the built-in tools alone.
    private func prepareExternalTools(for task: String, run: RunContext) async throws -> [ActionToolSpec] {
        do {
            return try await ownedOperation(run: run) { [router] in try await router.prepareTools() }
        } catch let error as ActionExecutionError where error == .noMCPServersEnabled || error == .noTools {
            try requireCurrent(run)
            guard NativeOpenAction.plansWithoutMCP(task) else { throw error }
            agentLog.info("No MCP inventory; planning with built-in open tools only")
            return []
        }
    }

    @MainActor
    private func performStep(spec: ActionToolSpec, argumentsJSON: String, run: RunContext) async throws -> String {
        dispatchPrecondition(condition: .onQueue(.main))
        try requireCurrent(run)

        let cacheKey = "\(spec.id)|\(argumentsJSON)"
        let cacheable = !spec.nativeObservation && !spec.requiresFreshObservation
        if cacheable, let cached = run.toolResults[cacheKey] {
            apply(.toolReused(spec), run: run)
            return cached.output
        }
        if let launched = speculativeLaunch(satisfying: spec, argumentsJSON: argumentsJSON, run: run) {
            apply(.toolReused(spec), run: run)
            return launched.summary
        }

        // A grounded mutation includes a separately audited post-approval observation.
        guard run.budget.consume(count: spec.nativePreflight == nil ? 1 : 2) else { throw ActionExecutionError.stepBudgetExceeded }
        stepIndex = run.budget.used
        apply(.toolStarted(spec), run: run)
        do {
            var output = try await ownedOperation(run: run) { [router] in
                try await router.execute(spec: spec, argumentsJSON: argumentsJSON)
            }
            try requireCurrent(run)
            if spec.compactObservation, !spec.nativeObservation {
                // The router returned the whole observation; hand the planner a
                // short ranked view of it rather than an arbitrary prefix.
                output = ObservationProjection.compact(json: output, focus: run.focusTerms)
                    ?? ActionResultText.truncate(output, limit: ActionResultText.modelLimit)
            }
            if spec.risk.meansChange { run.invalidateObservations() }
            if cacheable { run.toolResults[cacheKey] = .init(output: output, mutating: spec.risk.meansChange) }
            if spec.serverID == NativeOpenAction.serverID, spec.toolName == "open_app", let launched = NativeLaunchedApp(summary: output) {
                run.openedApps.removeAll { $0.processIdentifier == launched.processIdentifier }
                run.openedApps.append(launched)
            }
            apply(.toolFinished(spec, output), run: run)
            return output
        } catch {
            if !Task.isCancelled && !ActionErrorHandling.isCancellation(error) {
                if let action = error as? ActionExecutionError, case .approvalDenied = action {
                    apply(.toolDenied(spec), run: run)
                } else {
                    apply(.toolFailed(spec, ActionErrorHandling.userFacingMessage(for: error)), run: run)
                }
            }
            throw error
        }
    }

    /// An `open_app` call for the app that already opened while the user was
    /// speaking is satisfied by that launch. Names are compared by the bundle
    /// they resolve to, so "Notes", "the notes app", and aliases all match.
    private func speculativeLaunch(satisfying spec: ActionToolSpec, argumentsJSON: String, run: RunContext) -> NativeLaunchedApp? {
        guard let prior = run.speculative, let launched = prior.launched,
              spec.serverID == NativeOpenAction.serverID, spec.toolName == "open_app",
              case .openApp(let name)? = try? NativeOpenAction.decode(toolName: spec.toolName, argumentsJSON: argumentsJSON),
              let url = resolveApp(name) else { return nil }
        return url.standardizedFileURL.path == prior.action.app.url.standardizedFileURL.path ? launched : nil
    }

    private func requireCurrent(_ run: RunContext) throws {
        dispatchPrecondition(condition: .onQueue(.main))
        try Task.checkCancellation()
        guard activeRun === run else { throw ActionExecutionError.cancelled }
    }

    /// SDK tool callbacks may run in independent tasks. Keep cancellation handles
    /// for their work so ending a run also cancels approval/preflight waits.
    private func ownedOperation<Value: Sendable>(
        run: RunContext, operation: @escaping @MainActor @Sendable () async throws -> Value
    ) async throws -> Value {
        try requireCurrent(run)
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { throw ActionExecutionError.cancelled }
            try self.requireCurrent(run)
            return try await operation()
        }
        run.cancelOperations[id] = { task.cancel() }
        defer { run.cancelOperations[id] = nil }
        let value = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
        try requireCurrent(run)
        return value
    }

    private func apply(_ event: ActionPlanEvent, run: RunContext) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard activeRun === run else { return }
        checklist.apply(event)
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

    private func finish(_ phase: Phase, run: RunContext) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard activeRun === run else { return }
        // Invalidate ownership before cancellation resumes any old continuations.
        activeRun = nil
        runTask?.cancel()
        runTask = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        let cancellations = Array(run.cancelOperations.values)
        run.cancelOperations.removeAll()
        for cancel in cancellations { cancel() }
        run.toolResults.removeAll()
        router.cancelPendingApprovals()
        settings.isActionSessionActive = false
        settings.actionStatusText = ""
        if case .finished = phase { checklist.finish(succeeded: true) } else { checklist.finish(succeeded: false) }
        if case .finished(let message) = phase { liveMessage = message }
        if case .failed(let message) = phase {
            let issue = "Actions Mode: \(message)"
            settings.runtimeIssue = issue
            reportedRuntimeIssue = issue
        }
        self.phase = phase
        agentLog.info("Action session finished: \(String(describing: phase), privacy: .private)")
    }

    @MainActor
    final class StepBudget {
        let limit: Int
        private(set) var used = 0

        init(limit: Int) {
            self.limit = limit
        }

        func consume(count: Int = 1) -> Bool {
            guard count > 0, used + count <= limit else { return false }
            used += count
            return true
        }
    }
}
