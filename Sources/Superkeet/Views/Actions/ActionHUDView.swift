import SwiftUI

/// The floating Actions Mode panel. It asks for approval (a plan card for a
/// compound command, or one tool call), shows a live checklist while a
/// command runs, reports the outcome, and shows an app that opened while the
/// user was still speaking.
struct ActionHUDView: View {
    @ObservedObject private var approvals = ActionApprovalController.shared
    @ObservedObject private var agent = AgentSessionController.shared
    @ObservedObject private var speculation = SpeculativeLaunchCoordinator.shared

    @State private var showDetails = false

    /// Rows the checklist shows before folding older ones into a count.
    static let visibleChecklistRows = 6

    /// An early app launch is shown only while nothing else claims the HUD.
    private var speculativeActivity: SpeculativeLaunchCoordinator.Activity? {
        guard approvals.pending == nil, approvals.pendingPlan == nil, !agent.phase.showsHUD else { return nil }
        return speculation.activity
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
        }
        .padding(16)
        .frame(width: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            leadingIcon
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailingAction
        }
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if approvals.pendingPlan != nil {
            Image(systemName: "list.bullet.clipboard.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.orange)
        } else if approvals.pending != nil {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.orange)
        } else if agent.phase.isActive {
            ProgressView()
                .controlSize(.small)
        } else if let activity = speculativeActivity {
            switch activity {
            case .launching:
                ProgressView()
                    .controlSize(.small)
            case .launched:
                Image(systemName: "bolt.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.green)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.orange)
            }
        } else {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(iconColor)
        }
    }

    @ViewBuilder
    private var trailingAction: some View {
        if approvals.pending == nil, approvals.pendingPlan == nil, agent.phase.isActive {
            Button("Stop") { agent.cancel() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        } else if approvals.pending == nil, approvals.pendingPlan == nil, agent.phase.isOutcome {
            Button("Dismiss") { agent.reset() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private var title: String {
        if approvals.pendingPlan != nil { return "Approve this plan?" }
        if approvals.pending != nil { return "Approval needed" }
        switch agent.phase {
        case .planning, .running: return "Working…"
        case .finished: return "Done"
        case .failed: return "Couldn’t finish"
        default: break
        }
        switch speculativeActivity {
        case .launching(let name): return "Opening \(name)…"
        case .launched(let launched): return "Opened \(launched.name)"
        case .failed(let name, _): return "Couldn’t open \(name)"
        case nil: return "Superkeet"
        }
    }

    /// The spoken command while it runs, and progress when it has steps.
    private var subtitle: String? {
        guard approvals.pendingPlan == nil, agent.phase.showsHUD || approvals.pending != nil else { return nil }
        let command = agent.commandText
        guard !command.isEmpty else { return nil }
        if let step = currentStep, agent.phase.isActive {
            return "Step \(step.number) of \(step.total) · “\(command)”"
        }
        return "“\(command)”"
    }

    private var currentStep: (number: Int, total: Int)? {
        for item in agent.checklist.items.reversed() {
            if case .step(let number, let total) = item.kind { return (number, total) }
        }
        return nil
    }

    private var iconName: String {
        switch agent.phase {
        case .finished: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        default: return "wand.and.stars"
        }
    }

    private var iconColor: Color {
        switch agent.phase {
        case .finished: return .green
        case .failed: return .orange
        default: return .accentColor
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let plan = approvals.pendingPlan {
            planContent(plan)
        } else if let pending = approvals.pending {
            approvalContent(pending)
        } else if agent.phase.isActive {
            workingContent
        } else if agent.phase.isOutcome {
            outcomeContent
        } else if let activity = speculativeActivity {
            speculativeContent(activity)
        }
    }

    // MARK: Plan card

    private func planContent(_ plan: ActionPlanApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("“\(plan.command)”")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(plan.steps) { step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(step.number).")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(step.summary)
                                .font(.system(size: 13, weight: step.route == .alreadyDone ? .regular : .medium))
                                .foregroundStyle(step.route == .alreadyDone ? .secondary : .primary)
                                .fixedSize(horizontal: false, vertical: true)
                            if step.summary != step.text {
                                Text(step.text)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        if let risk = step.risk {
                            riskBadge(risk)
                        } else if step.route == .planned {
                            Text("Planned")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }
                }
            }

            if plan.hasPlannedSteps {
                Text("Planned steps use the on-device model; their tool calls still ask before making changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button("Deny") { approvals.resolvePlan(.deny, requestID: plan.id) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Step by Step") { approvals.resolvePlan(.stepByStep, requestID: plan.id) }
                Button("Approve All") { approvals.resolvePlan(.approveAll, requestID: plan.id) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Tool approval

    private func approvalContent(_ pending: ActionApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                riskBadge(pending.tool.risk)
                Text(intentSummary(pending))
                    .font(.system(size: 13, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Button("Deny") { approvals.resolve(.deny, requestID: pending.id) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if ActionApprovalGrant.supportsSimilar(pending.tool, argumentsJSON: pending.argumentsJSON) {
                    Button("Approve Similar") { approvals.approveSimilar(requestID: pending.id) }
                        .keyboardShortcut(.return, modifiers: [.shift])
                        .help("Also allow \(pending.tool.displayName) again for this app during this command")
                }
                Button("Approve") { approvals.resolve(.approve, requestID: pending.id) }
                    .keyboardShortcut(.defaultAction)
            }

            DisclosureGroup("Details", isExpanded: $showDetails) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(pending.tool.displayName)
                        .font(.system(size: 11, weight: .medium))
                    if !pending.tool.description.isEmpty {
                        Text(firstSentence(pending.tool.description))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ScrollView {
                        Text(prettyArguments(pending.argumentsJSON))
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
                .padding(.top, 4)
            }
            .font(.caption)
        }
    }

    // MARK: Working and outcome

    @ViewBuilder
    private var workingContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            checklistView
            if !agent.liveMessage.isEmpty {
                Text(agent.liveMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var outcomeContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch agent.phase {
            case .finished(let message):
                Text(message.isEmpty ? "All done." : message)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let message):
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            default:
                EmptyView()
            }
            if !agent.checklist.isEmpty {
                Divider()
                checklistView
            }
        }
    }

    @ViewBuilder
    private var checklistView: some View {
        let visible = agent.checklist.visibleItems(limit: Self.visibleChecklistRows)
        VStack(alignment: .leading, spacing: 4) {
            if visible.hidden > 0 {
                Text("… \(visible.hidden) earlier")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            ForEach(visible.items) { item in
                checklistRow(item)
            }
        }
    }

    private func checklistRow(_ item: ActionChecklistItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            statusIcon(item.status)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(rowTitle(item))
                    .font(.system(size: 12, weight: rowIsStep(item) ? .semibold : .regular))
                    .foregroundStyle(item.status == .skipped || item.status == .info ? .secondary : .primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = item.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, rowIsStep(item) ? 0 : 10)
    }

    private func rowIsStep(_ item: ActionChecklistItem) -> Bool {
        if case .step = item.kind { return true }
        return false
    }

    private func rowTitle(_ item: ActionChecklistItem) -> String {
        if case .step(let number, let total) = item.kind { return "Step \(number) of \(total): \(item.title)" }
        return item.title
    }

    @ViewBuilder
    private func statusIcon(_ status: ActionChecklistItem.Status) -> some View {
        switch status {
        case .running:
            ProgressView().controlSize(.mini)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .reused:
            Image(systemName: "arrow.uturn.backward.circle.fill").foregroundStyle(.green.opacity(0.8))
        case .skipped:
            Image(systemName: "bolt.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.orange)
        case .denied:
            Image(systemName: "hand.raised.circle.fill").foregroundStyle(.orange)
        case .pending:
            Image(systemName: "circle").foregroundStyle(.tertiary)
        case .info:
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
    }

    // MARK: Speculative launch

    @ViewBuilder
    private func speculativeContent(_ activity: SpeculativeLaunchCoordinator.Activity) -> some View {
        switch activity {
        case .launching:
            Text("Heard the app name while you were speaking; opening it right away.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .launched(let launched):
            Text(launched.windowReady ? "Ready. Keep talking — the rest of your command runs when you finish."
                 : "Opening. Keep talking — the rest of your command runs when you finish.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(_, let message):
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Helpers

    private func intentSummary(_ pending: ActionApprovalRequest) -> String {
        pending.tool.approvalSummary ?? ActionIntentFormatter.summary(toolName: pending.tool.toolName, argumentsJSON: pending.argumentsJSON)
            ?? "Run \(pending.tool.displayName)"
    }

    private func firstSentence(_ text: String) -> String {
        let singleLine = text.replacingOccurrences(of: "\n", with: " ")
        guard let end = singleLine.firstIndex(where: { $0 == "." || $0 == "!" || $0 == "?" }) else {
            return String(singleLine.prefix(120))
        }
        return String(singleLine[...end])
    }

    private func prettyArguments(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: pretty, encoding: .utf8) else {
            return json
        }
        return string
    }

    private func riskBadge(_ risk: ActionToolRisk) -> some View {
        Text(risk.title)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color(for: risk))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color(for: risk).opacity(0.12))
            .clipShape(Capsule())
    }

    private func color(for risk: ActionToolRisk) -> Color {
        switch risk {
        case .readOnly: return .green
        case .mutating: return .orange
        case .destructive: return .red
        }
    }
}
