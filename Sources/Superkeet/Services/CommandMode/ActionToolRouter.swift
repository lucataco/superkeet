import Foundation

@MainActor
final class ActionToolRouter: ActionRouting {
    static let shared = ActionToolRouter()

    private let manager: MCPClientManager
    private let approvals: ActionApprovalController
    private let audit: ActionAuditStore
    private let settings: AppSettings

    init(
        manager: MCPClientManager? = nil,
        approvals: ActionApprovalController? = nil,
        audit: ActionAuditStore? = nil,
        settings: AppSettings? = nil
    ) {
        self.manager = manager ?? .shared
        self.approvals = approvals ?? .shared
        self.audit = audit ?? .shared
        self.settings = settings ?? .shared
    }

    func prepareTools() async throws -> [ActionToolSpec] {
        let servers = settings.actionsEnabled ? MCPServerConfigStore.shared.enabledServers : []
        for server in servers where !manager.state(for: server.id).isConnected {
            await manager.connect(server)
        }
        return manager.allTools().map(ActionToolSpec.init(descriptor:))
    }

    func execute(spec: ActionToolSpec, argumentsJSON: String) async throws -> String {
        let argumentsJSON = ActionArgumentNormalizer.normalize(
            argumentsJSON: argumentsJSON,
            schemaJSON: spec.inputSchemaJSON
        )
        try ActionLimits.validateArguments(argumentsJSON)

        if settings.actionApprovalPolicy.requiresApproval(for: spec.risk) {
            let request = ActionApprovalRequest(tool: spec, argumentsJSON: argumentsJSON)
            let decision = await approvals.request(request)
            guard decision == .approve else {
                record(spec, argumentsJSON, outcome: "denied")
                throw ActionExecutionError.approvalDenied(spec.displayName)
            }
        }

        do {
            let timeout = max(5, settings.actionTimeoutSeconds)
            let output = try await AsyncTimeout.run(
                seconds: Double(timeout),
                timeoutError: ActionExecutionError.timedOut
            ) { [manager] in
                try await manager.callTool(
                    serverID: spec.serverID,
                    toolName: spec.toolName,
                    argumentsJSON: argumentsJSON
                )
            }
            record(spec, argumentsJSON, outcome: "succeeded", detail: ActionResultText.truncate(output))
            return ActionResultText.truncate(output, limit: ActionResultText.modelLimit)
        } catch {
            record(spec, argumentsJSON, outcome: "failed", detail: error.localizedDescription)
            throw error
        }
    }

    private func record(_ spec: ActionToolSpec, _ argumentsJSON: String, outcome: String, detail: String? = nil) {
        guard settings.actionAuditEnabled else { return }
        audit.record(
            serverName: spec.serverName,
            toolName: spec.toolName,
            risk: spec.risk,
            argumentsJSON: argumentsJSON,
            outcome: outcome,
            detail: detail.map(ActionRedactor.redactText)
        )
    }
}
