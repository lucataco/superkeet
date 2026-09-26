import SwiftUI

struct ActionHUDView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var approvals = ActionApprovalController.shared
    @ObservedObject private var agent = AgentSessionController.shared
    @ObservedObject private var speculation = SpeculativeLaunchCoordinator.shared
    @ObservedObject private var session = ListeningSessionController.shared

    @State private var showDetails = false

    static let visibleChecklistRows = 6
    /// Early steps shown under the live transcript while the user is still speaking.
    static let visibleEarlySteps = 4
    static let sessionPrompt = "Go ahead, I’m listening."

    private var showsActionContent: Bool {
        approvals.pending != nil || approvals.pendingPlan != nil || agent.phase.showsHUD
    }

    /// Live text is flowing, or a listening session is between utterances.
    private var isListening: Bool { speculation.listening != nil || session.isActive }

    private var listeningPlaceholder: String { session.isActive ? Self.sessionPrompt : "Say a command…" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
            if isListening, showsActionContent {
                Divider()
                listeningFooter(speculation.listening?.transcript ?? "")
            }
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
        } else if isListening, !agent.phase.isOutcome {
            Image(systemName: "waveform")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.accentColor)
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
        } else if approvals.pending == nil, approvals.pendingPlan == nil, session.isActive {
            Button("Stop") { session.end(dispatchPending: false) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Stop listening (\(settings.commandHotkeyDisplayName) or Escape)")
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
        if speculation.listening != nil { return settings.isRecording ? "Listening…" : "Transcribing…" }
        return session.isActive ? "Listening" : "Superkeet"
    }

    private var subtitle: String? {
        if session.isActive, !agent.phase.showsHUD, approvals.pending == nil, approvals.pendingPlan == nil {
            let count = session.dispatchedCommands
            let commands = count == 0 ? "" : " · \(count) command\(count == 1 ? "" : "s") so far"
            return "Press \(settings.commandHotkeyDisplayName) to stop\(commands)"
        }
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
        } else if let listening = speculation.listening {
            listeningContent(listening)
        } else if session.isActive {
            // Between utterances: the take just ended and the next one is opening.
            LiveTranscriptText(transcript: "", isRecording: false, placeholder: Self.sessionPrompt)
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
            if settings.actionApprovalPolicy == .autoApprove {
                Label("Just Do It · destructive tools still ask", systemImage: "bolt.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            queuedContent
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
            queuedContent
        }
    }

    @ViewBuilder
    private var queuedContent: some View {
        if !agent.queuedCommands.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(agent.queuedCommands.enumerated()), id: \.offset) { _, command in
                    Text("Next: “\(command)”")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
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

    private func listeningContent(_ listening: SpeculativeLaunchCoordinator.Listening) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LiveTranscriptText(
                transcript: listening.transcript, isRecording: settings.isRecording,
                placeholder: listeningPlaceholder
            )
            if let activity = speculation.activity {
                speculativeStatus(activity)
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            // Everything done while speaking, oldest first; the newest few fit in the pill.
            ForEach(Array(speculation.stepActivities.suffix(Self.visibleEarlySteps).enumerated()), id: \.element.step.index) { _, step in
                stepStatus(step)
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func stepStatus(_ step: SpeculativeLaunchCoordinator.StepActivity) -> some View {
        switch step {
        case .running(let running):
            let summary = SpeculativeStepResult(step: running, output: nil, failure: nil).summary
            Label("\(summary)…", systemImage: "bolt.fill")
                .foregroundStyle(.secondary)
        case .done(let result):
            Label(result.doneDescription, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let result):
            Label("Couldn’t \(result.lowercasedSummary)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help(result.failure ?? "")
        }
    }

    private func listeningFooter(_ transcript: String) -> some View {
        Label("Listening: \(transcript.isEmpty ? listeningPlaceholder : transcript)", systemImage: "waveform")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func speculativeStatus(_ activity: SpeculativeLaunchCoordinator.Activity) -> some View {
        switch activity {
        case .launching(let name):
            Label("Opening \(name)…", systemImage: "bolt.fill")
                .foregroundStyle(.secondary)
        case .launched(let launched):
            Label("Opened \(launched.name)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let name, let message):
            Label("Couldn’t open \(name)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help(message)
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

private struct LiveTranscriptText: View {
    let transcript: String
    let isRecording: Bool
    var placeholder = "Say a command…"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cursorVisible = true

    private var displayedText: String { transcript.isEmpty ? placeholder : transcript }

    var body: some View {
        (Text(displayedText) + Text(isRecording ? "▍" : "").foregroundColor(cursorVisible ? .primary : .clear))
            .font(.system(size: 13))
            .foregroundStyle(.primary)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(displayedText)
            .task(id: isRecording && !reduceMotion) {
                cursorVisible = true
                guard isRecording, !reduceMotion else { return }
                do {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .milliseconds(500))
                        cursorVisible.toggle()
                    }
                } catch is CancellationError {
                } catch { }
            }
    }
}
