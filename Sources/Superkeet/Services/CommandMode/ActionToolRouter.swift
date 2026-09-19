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
    // Resolve persisted configuration (and its migrations) when discovering MCP tools.
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
        // Test/Reconnect may leave disabled servers connected. Re-read the
        // configuration after awaits, since a server may have been disabled meanwhile.
        let enabledIDs = settings.actionsEnabled ? Set(configStore.enabledServers.map(\.id)) : []
        guard !enabledIDs.isEmpty else { throw ActionExecutionError.noMCPServersEnabled }
        let tools = manager.allTools().filter { enabledIDs.contains($0.serverID) }.map(ActionToolSpec.init(descriptor:))
        guard !tools.isEmpty else { throw ActionExecutionError.noTools }
        return ActionObservationPolicy.markingLiveObservations(tools)
    }

    func execute(spec: ActionToolSpec, argumentsJSON: String) async throws -> String {
        dispatchPrecondition(condition: .onQueue(.main))
        try Task.checkCancellation()
        // Built-in tool policy belongs to the app, including its mutating risk.
        let spec = try canonicalSpec(spec)
        var argumentsJSON = ActionArgumentNormalizer.normalize(
            argumentsJSON: argumentsJSON,
            schemaJSON: spec.inputSchemaJSON
        )
        if spec.compactObservation, !spec.nativeObservation {
            argumentsJSON = ActionArgumentNormalizer.applyingObservationDefaults(argumentsJSON: argumentsJSON, schemaJSON: spec.inputSchemaJSON)
        }
        try ActionLimits.validateArguments(argumentsJSON)

        var preapproved = false
        if settings.actionApprovalPolicy.requiresApproval(for: spec.risk) {
            if approvals.isGranted(spec, argumentsJSON: argumentsJSON) {
                // The user already allowed this step on the plan card, or this
                // kind of call via "Approve similar", during this command.
                preapproved = true
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
        }

        do {
            try Task.checkCancellation()
            if let preflight = spec.nativePreflight {
                // Approval can remain open while the UI changes. Observe again and
                // renew only the exact approved control's capability, never re-ground.
                argumentsJSON = try await refresh(preflight, spec: spec, argumentsJSON: argumentsJSON)
            }
            try Task.checkCancellation()
            let timeout = max(5, settings.actionTimeoutSeconds)
            let finalArguments = argumentsJSON
            let grounding = spec.nativeObservation || spec.groundingDecision != nil
            // Planner-facing observations also ask for structured content; the
            // controller projects it into compact text. Servers without it fall
            // back to their text result.
            let structured = grounding || spec.compactObservation
            let output = try await AsyncTimeout.run(
                seconds: Double(timeout),
                timeoutError: ActionExecutionError.timedOut
            ) { [callTool, nativeExecutor] in
                if spec.serverID == NativeActionExecutor.serverID {
                    let action = try NativeOpenAction.decode(toolName: spec.toolName, argumentsJSON: finalArguments)
                    return try await nativeExecutor.execute(action)
                }
                return try await callTool(spec.serverID, spec.toolName, finalArguments, structured)
            }
            if grounding { _ = try NativeGroundingJSON.object(output) }
            record(spec, argumentsJSON, outcome: preapproved ? "succeeded (pre-approved)" : "succeeded", detail: structured ? nil : output)
            // Grounding needs the complete observation; a compact observation is
            // returned whole too, so the controller can project it before truncating.
            if structured { return output }
            return ActionResultText.truncate(output, limit: ActionResultText.modelLimit)
        } catch {
            let cancelled = Task.isCancelled || ActionErrorHandling.isCancellation(error)
            let observation = spec.nativeObservation || spec.groundingDecision != nil || spec.compactObservation
            record(spec, argumentsJSON, outcome: cancelled ? "cancelled" : "failed",
                   detail: observation ? nil : ActionErrorHandling.userFacingMessage(for: error))
            throw error
        }
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
                         argumentsJSON: (try? NativeGroundingJSON.encode(["steps": plan.steps.map(\.summary)])) ?? "{}",
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

    private func refresh(_ preflight: NativeActionPreflight, spec: ActionToolSpec, argumentsJSON: String) async throws -> String {
        var observation = ActionToolSpec(descriptor: MCPToolDescriptor(
            serverID: spec.serverID, serverName: spec.serverName, name: "get_window_state", title: nil,
            description: "Refresh the approved native control", risk: .readOnly, inputSchemaJSON: preflight.observationSchemaJSON
        ))
        observation.nativeObservation = true
        let arguments = try NativeGroundingJSON.encode(["pid": preflight.window.pid, "window_id": preflight.window.windowID,
                                                       "include_screenshot": false, "session": preflight.session])
        let json = try await execute(spec: observation, argumentsJSON: arguments)
        let snapshot = try NativeGroundingSnapshot(json: json, window: preflight.window)
        return try preflight.refreshedArguments(argumentsJSON, snapshot: snapshot)
    }

    private func record(_ spec: ActionToolSpec, _ argumentsJSON: String, outcome: String, detail: String? = nil) {
        guard settings.actionAuditEnabled else { return }
        audit.record(
            serverName: spec.serverName,
            toolName: spec.toolName,
            risk: spec.risk,
            argumentsJSON: argumentsJSON,
            outcome: outcome,
            detail: detail.map { ActionResultText.truncate(ActionRedactor.redactText($0)) },
            grounding: spec.groundingDecision,
            redactionContext: spec.nativeObservation || spec.nativePreflight != nil || spec.groundingDecision != nil ? .groundingUI : .toolArguments
        )
    }
}
