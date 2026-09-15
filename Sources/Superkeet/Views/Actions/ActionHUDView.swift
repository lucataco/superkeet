import SwiftUI

/// A small, focused overlay that only appears when the user must act
/// (approve a tool call) or when a session has produced a result.
struct ActionHUDView: View {
    @ObservedObject private var approvals = ActionApprovalController.shared
    @ObservedObject private var agent = AgentSessionController.shared

    @State private var showDetails = false

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

    private var header: some View {
        HStack(spacing: 10) {
            leadingIcon
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Spacer(minLength: 8)
            trailingAction
        }
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if approvals.pending != nil {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.orange)
        } else if agent.phase.isActive {
            ProgressView()
                .controlSize(.small)
        } else {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(iconColor)
        }
    }

    @ViewBuilder
    private var trailingAction: some View {
        if approvals.pending == nil, agent.phase.isActive {
            Button("Stop") { agent.cancel() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        } else if approvals.pending == nil, agent.phase.isOutcome {
            Button("Dismiss") { agent.reset() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let pending = approvals.pending {
            approvalContent(pending)
        } else if agent.phase.isOutcome {
            outcomeContent
        }
    }

    private var title: String {
        if approvals.pending != nil { return "Approval needed" }
        switch agent.phase {
        case .planning, .running: return "Working…"
        case .finished: return "Done"
        case .failed: return "Couldn’t finish"
        default: return "Superkeet"
        }
    }

    private var iconName: String {
        if approvals.pending != nil { return "hand.raised.fill" }
        switch agent.phase {
        case .finished: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        default: return "wand.and.stars"
        }
    }

    private var iconColor: Color {
        if approvals.pending != nil { return .orange }
        switch agent.phase {
        case .finished: return .green
        case .failed: return .orange
        default: return .accentColor
        }
    }

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
                Button("Deny") { approvals.resolve(.deny) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Approve") { approvals.resolve(.approve) }
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

    @ViewBuilder
    private var outcomeContent: some View {
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
    }

    private func intentSummary(_ pending: ActionApprovalRequest) -> String {
        ActionIntentFormatter.summary(toolName: pending.tool.toolName, argumentsJSON: pending.argumentsJSON)
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
