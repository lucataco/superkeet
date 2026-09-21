import Foundation

@MainActor
protocol ActionMCPManaging: AnyObject, Sendable {
    func state(for id: UUID) -> MCPClientManager.ConnectionState
    func connect(_ server: MCPServerConfiguration) async
    func allTools() -> [MCPToolDescriptor]
    func callTool(serverID: UUID, toolName: String, argumentsJSON: String, structured: Bool) async throws -> String
}

@MainActor
final class ActionToolRouter: ActionRouting {
    static let shared = ActionToolRouter()

    private let manager: any ActionMCPManaging
    private let injectedConfigStore: MCPServerConfigStore?
    private var configStore: MCPServerConfigStore { injectedConfigStore ?? .shared }
    private let approvals: ActionApprovalController
    private let audit: ActionAuditStore
    private let settings: AppSettings
    private let nativeExecutor: any NativeActionExecuting
    private let callTool: @Sendable (UUID, String, String, Bool) async throws -> String

    init(
        manager: (any ActionMCPManaging)? = nil,
        approvals: ActionApprovalController? = nil,
        audit: ActionAuditStore? = nil,
        settings: AppSettings? = nil,
        callTool: (@Sendable (UUID, String, String, Bool) async throws -> String)? = nil,
        nativeExecutor: (any NativeActionExecuting)? = nil,
        configStore: MCPServerConfigStore? = nil
    ) {
        self.manager = manager ?? MCPClientManager.shared
        self.injectedConfigStore = configStore
        self.approvals = approvals ?? .shared
        self.audit = audit ?? .shared
        self.settings = settings ?? .shared
        self.nativeExecutor = nativeExecutor ?? NativeActionExecutor.shared
        let resolvedManager = self.manager
        self.callTool = callTool ?? { serverID, name, arguments, structured in
            try await resolvedManager.callTool(serverID: serverID, toolName: name, argumentsJSON: arguments, structured: structured)
        }
    }

    func prepareTools() async throws -> [ActionToolSpec] {
        dispatchPrecondition(condition: .onQueue(.main))
        try Task.checkCancellation()
        let servers = settings.actionsEnabled ? configStore.enabledServers : []
        guard !servers.isEmpty else { throw ActionExecutionError.noMCPServersEnabled }
        for server in servers where !manager.state(for: server.id).isConnected {
            try Task.checkCancellation()
            guard settings.actionsEnabled, configStore.enabledServers.contains(where: { $0.id == server.id }) else { continue }
            await manager.connect(server)
        }
        try Task.checkCancellation()
        let enabledIDs = settings.actionsEnabled ? Set(configStore.enabledServers.map(\.id)) : []
        guard !enabledIDs.isEmpty else { throw ActionExecutionError.noMCPServersEnabled }
        let tools = manager.allTools().filter { enabledIDs.contains($0.serverID) }.map(ActionToolSpec.init(descriptor:))
        guard !tools.isEmpty else { throw ActionExecutionError.noTools }
        return ActionObservationPolicy.markingLiveObservations(tools)
    }

    func execute(spec: ActionToolSpec, argumentsJSON: String) async throws -> String {
        dispatchPrecondition(condition: .onQueue(.main))
        try Task.checkCancellation()
        let canonical = try canonicalSpec(spec)
        var argumentsJSON = ActionArgumentNormalizer.normalize(
            argumentsJSON: argumentsJSON,
            schemaJSON: canonical.inputSchemaJSON
        )
        if canonical.compactObservation {
            argumentsJSON = ActionArgumentNormalizer.applyingObservationDefaults(argumentsJSON: argumentsJSON, schemaJSON: canonical.inputSchemaJSON)
        }
        try ActionLimits.validateArguments(argumentsJSON)
        // Built-in actions decide their own approval exemption from their arguments (⌘N is
        // harmless, ⌘Q is not), so decode before consulting the policy.
        let nativeAction: NativeOpenAction? = canonical.serverID == NativeActionExecutor.serverID
            ? try NativeOpenAction.decode(toolName: canonical.toolName, argumentsJSON: argumentsJSON)
            : nil
        let spec = nativeAction?.spec ?? canonical

        var successOutcome = "succeeded"
        if settings.actionApprovalPolicy.requiresApproval(for: spec) {
            if approvals.isGranted(spec, argumentsJSON: argumentsJSON) {
                successOutcome = "succeeded (pre-approved)"
            } else {
                let request = ActionApprovalRequest(tool: spec, argumentsJSON: argumentsJSON)
                let decision = await approvals.request(request)
                guard !Task.isCancelled else {
                    record(spec, argumentsJSON, outcome: "cancelled")
                    throw ActionExecutionError.cancelled
                }
                guard decision == .approve else {
                    record(spec, argumentsJSON, outcome: "denied")
                    throw ActionExecutionError.approvalDenied(spec.displayName)
                }
            }
        } else if spec.risk.meansChange {
            successOutcome = "succeeded (auto-approved)"
        }

        let clock = ContinuousClock()
        let started = clock.now
        do {
            try Task.checkCancellation()
            let timeout = max(5, settings.actionTimeoutSeconds)
            let finalArguments = argumentsJSON
            let structured = spec.compactObservation
            let output = try await AsyncTimeout.run(
                seconds: Double(timeout),
                timeoutError: ActionExecutionError.timedOut
            ) { [callTool, nativeExecutor] in
                if let nativeAction {
                    return try await nativeExecutor.execute(nativeAction)
                }
                do {
                    return try await callTool(spec.serverID, spec.toolName, finalArguments, structured)
                } catch {
                    try Task.checkCancellation()
                    guard !ActionErrorHandling.isCancellation(error), spec.toolName != "start_session",
                          let session = Self.endedSessionID(in: error.localizedDescription) else { throw error }
                    let arguments = try ActionJSON.encode(["session": session])
                    _ = try await callTool(spec.serverID, "start_session", arguments, false)
                    try Task.checkCancellation()
                    return try await callTool(spec.serverID, spec.toolName, finalArguments, structured)
                }
            }
            record(spec, argumentsJSON, outcome: successOutcome, detail: structured ? nil : output,
                   durationMs: Self.milliseconds(started.duration(to: clock.now)))
            if structured { return output }
            return ActionResultText.truncate(output, limit: ActionResultText.modelLimit)
        } catch {
            let cancelled = Task.isCancelled || ActionErrorHandling.isCancellation(error)
            // The error text is the only clue to why an observation failed; always keep it.
            record(spec, argumentsJSON, outcome: cancelled ? "cancelled" : "failed",
                   detail: ActionErrorHandling.userFacingMessage(for: error),
                   durationMs: Self.milliseconds(started.duration(to: clock.now)))
            throw error
        }
    }

    nonisolated static func milliseconds(_ duration: Duration) -> Int {
        Int(duration / .milliseconds(1))
    }

    nonisolated static func endedSessionID(in message: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: #"\bsession '([^'\r\n]+)' has ended\b"#, options: .caseInsensitive),
              let match = expression.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let range = Range(match.range(at: 1), in: message) else { return nil }
        return String(message[range])
    }

    func requestPlanApproval(_ plan: ActionPlanApprovalRequest) async -> ActionPlanApprovalDecision {
        dispatchPrecondition(condition: .onQueue(.main))
        let decision = await approvals.requestPlan(plan)
        if settings.actionAuditEnabled {
            let outcome: String
            switch decision {
            case .approveAll: outcome = "plan approved"
            case .stepByStep: outcome = "plan step by step"
            case .deny: outcome = "plan denied"
            }
            audit.record(serverName: "superkeet", toolName: "plan", risk: .mutating,
                         argumentsJSON: (try? ActionJSON.encode(["steps": plan.steps.map(\.summary)])) ?? "{}",
                         outcome: outcome)
        }
        return decision
    }

    func cancelPendingApprovals() {
        dispatchPrecondition(condition: .onQueue(.main))
        approvals.cancelPending()
    }

    private func canonicalSpec(_ spec: ActionToolSpec) throws -> ActionToolSpec {
        guard spec.serverID == NativeActionExecutor.serverID else { return spec }
        guard let native = NativeOpenAction.tools.first(where: { $0.toolName == spec.toolName }) else {
            throw NativeOpenActionError.invalidArguments("Unknown built-in open tool '\(spec.toolName)'.")
        }
        return native
    }

    private func record(_ spec: ActionToolSpec, _ argumentsJSON: String, outcome: String, detail: String? = nil, durationMs: Int? = nil) {
        guard settings.actionAuditEnabled else { return }
        audit.record(
            serverName: spec.serverName,
            toolName: spec.toolName,
            risk: spec.risk,
            argumentsJSON: argumentsJSON,
            outcome: outcome,
            detail: detail.map { ActionResultText.truncate(ActionRedactor.redactText($0)) },
            durationMs: durationMs
        )
    }
}
