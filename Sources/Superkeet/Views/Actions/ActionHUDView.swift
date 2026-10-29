import SwiftUI

struct ActionHUDView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var approvals = ActionApprovalController.shared
    @ObservedObject private var agent = AgentSessionController.shared
    @ObservedObject private var speculation = SpeculativeLaunchCoordinator.shared
    @ObservedObject private var session = ListeningSessionController.shared

    @State private var showDetails = false

    static let sessionPrompt = "Go ahead, I’m listening."

    private enum Control {
        case stopRun
        case dismissOutcome
        case stopListening

        var title: String { self == .dismissOutcome ? "Dismiss" : "Stop" }
    }

    private var showsActionContent: Bool {
        approvals.pending != nil || approvals.pendingPlan != nil || agent.phase.showsHUD
    }

    private var isListening: Bool { speculation.listening != nil || session.isActive }

    private var listeningPlaceholder: String { session.isActive ? Self.sessionPrompt : "Say a command…" }

    private var hasQuestion: Bool { approvals.pending != nil || approvals.pendingPlan != nil }

    var body: some View {
        ActionHUDCard(header: header, footer: footer, onButton: performControl) {
            content
        }
    }

    private var footer: String? {
        guard isListening, showsActionContent else { return nil }
        let transcript = speculation.listening?.transcript ?? ""
        return "Listening: \(transcript.isEmpty ? listeningPlaceholder : transcript)"
    }

    private var control: Control? {
        guard !hasQuestion else { return nil }
        if agent.phase.isActive { return .stopRun }
        if agent.phase.isOutcome { return .dismissOutcome }
        return session.isActive ? .stopListening : nil
    }

    private func performControl() {
        switch control {
        case .stopRun: agent.cancel()
        case .dismissOutcome: agent.reset()
        case .stopListening: session.end(dispatchPending: false)
        case nil: break
        }
    }

    private var header: ActionHUDHeader {
        ActionHUDHeader(
            icon: icon,
            title: title,
            subtitle: subtitle,
            button: control?.title,
            buttonHelp: control == .stopListening ? "Stop listening (\(settings.commandHotkeyDisplayName) or Escape)" : nil
        )
    }

    private var icon: ActionHUDHeader.Icon {
        if approvals.pendingPlan != nil { return .plan }
        if approvals.pending != nil { return .approval }
        if agent.phase.isActive { return .working }
        if isListening, !agent.phase.isOutcome { return .listening }
        switch agent.phase {
        case .finished: return .done
        case .failed: return .failed
        default: return .idle
        }
    }

    private var title: String {
        if approvals.pendingPlan != nil { return "Approve this plan?" }
        if approvals.pending != nil { return "Approval needed" }
        switch agent.phase {
        case .planning, .running: return "Working…"
        case .finished: return "Done"
        case .failed: return agent.checklist.failureTitle
        default: break
        }
        if speculation.listening != nil { return settings.isRecording ? "Listening…" : "Transcribing…" }
        return session.isActive ? "Listening" : "Superkeet"
    }

    private var subtitle: String? {
        if session.isActive, !agent.phase.showsHUD, !hasQuestion {
            let count = session.dispatchedCommands
            let commands = count == 0 ? "" : " · \(count) command\(count == 1 ? "" : "s") so far"
            return "Press \(settings.commandHotkeyDisplayName) to stop\(commands)"
        }
        guard approvals.pendingPlan == nil, agent.phase.showsHUD || approvals.pending != nil else { return nil }
        let command = agent.commandText
        return command.isEmpty ? nil : "“\(command)”"
    }

    @ViewBuilder
    private var content: some View {
        if let plan = approvals.pendingPlan {
            planContent(plan)
        } else if let pending = approvals.pending {
            approvalContent(pending)
        } else if agent.phase.isActive {
            ActionHUDBody(
                note: agent.liveMessage.isEmpty ? nil : .progress(agent.liveMessage),
                lines: agent.checklist.lines, queued: agent.queuedCommands
            )
        } else if agent.phase.isOutcome {
            outcomeContent
        } else if let listening = speculation.listening {
            ActionHUDBody(
                transcript: .init(text: listening.transcript, isRecording: settings.isRecording, placeholder: listeningPlaceholder),
                lines: ActionLine.early(activity: speculation.activity, steps: speculation.stepActivities)
            )
        } else if session.isActive {
            ActionHUDBody(transcript: .init(text: "", isRecording: false, placeholder: Self.sessionPrompt))
        }
    }

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

    @ViewBuilder
    private var outcomeContent: some View {
        switch agent.phase {
        case .finished(let message):
            ActionHUDBody(
                note: agent.checklist.outcomeText(message: message, succeeded: true).map(ActionHUDBody.Note.result),
                lines: agent.checklist.lines, queued: agent.queuedCommands
            )
        case .failed(let message):
            ActionHUDBody(
                note: agent.checklist.outcomeText(message: message, succeeded: false).map(ActionHUDBody.Note.problem),
                lines: agent.checklist.lines, queued: agent.queuedCommands
            )
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
