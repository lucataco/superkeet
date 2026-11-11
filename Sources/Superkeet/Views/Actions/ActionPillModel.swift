import Combine
import Foundation

/// Gathers the Actions HUD inputs into an `ActionPillState` and keeps the bits of pill state that
/// depend on time: the brief confirmation after an action finishes and the user's "…" expansion.
@MainActor
final class ActionPillModel: ObservableObject {
    static let shared = ActionPillModel()

    @Published private(set) var state = ActionPillState()
    @Published private(set) var presentation = ActionPillContent.Presentation.card

    private var cancellables: Set<AnyCancellable> = []
    private var started = false
    private var seenDone: Set<String> = []
    private var lastTakeID: String?
    private var userExpanded = false
    private var confirmation: String?
    private var confirmationTask: Task<Void, Never>?

    var canCollapse: Bool { state.compactEnabled && userExpanded && !state.hasQuestion }

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !started else { return }
        started = true
        let agent = AgentSessionController.shared
        let speculation = SpeculativeLaunchCoordinator.shared
        let changes: [AnyPublisher<Void, Never>] = [
            AppSettings.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            ActionApprovalController.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            agent.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            speculation.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            ListeningSessionController.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher()
        ]
        // objectWillChange fires before the new value lands, so read the sources a turn later.
        Publishers.MergeMany(changes)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &cancellables)
        refresh()
    }

    func toggleExpanded() {
        dispatchPrecondition(condition: .onQueue(.main))
        userExpanded.toggle()
        refresh()
    }

    func expand() {
        dispatchPrecondition(condition: .onQueue(.main))
        userExpanded = true
        refresh()
    }

    /// The HUD went away; the next session starts compact again.
    func hudHidden() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard userExpanded || confirmation != nil else { return }
        userExpanded = false
        clearConfirmation()
        refresh()
    }

    private func refresh() {
        let settings = AppSettings.shared
        let approvals = ActionApprovalController.shared
        let agent = AgentSessionController.shared
        let speculation = SpeculativeLaunchCoordinator.shared
        let early = ActionLine.early(activity: speculation.activity, steps: speculation.stepActivities)
        let lines = early + agent.checklist.lines

        let takeID = speculation.listening?.sessionID
        if let takeID, takeID != lastTakeID {
            // A new take: anything already finished was confirmed by the last one.
            seenDone = ActionPillContent.doneTitles(in: lines)
        }
        lastTakeID = takeID
        if let newest = ActionPillContent.newlyDone(in: lines, seen: seenDone) {
            confirm(newest)
        }
        seenDone.formUnion(ActionPillContent.doneTitles(in: lines))

        var next = ActionPillState(
            compactEnabled: settings.actionHUDCompactPill,
            hasQuestion: approvals.pending != nil || approvals.pendingPlan != nil,
            userExpanded: userExpanded,
            phase: agent.phase,
            isSessionActive: ListeningSessionController.shared.isActive,
            transcript: speculation.listening?.transcript,
            runningStep: ActionPillContent.runningStep(in: lines),
            liveMessage: agent.liveMessage,
            confirmation: confirmation
        )
        if case .failed(let message) = agent.phase {
            next.failure = ActionPillContent.failureLine(checklist: agent.checklist, message: message)
        }
        if case .finished = agent.phase {
            next.reply = ActionPillContent.replyLine(in: agent.checklist)
        }
        if next != state { state = next }
        let resolved = ActionPillContent.presentation(for: next)
        if resolved != presentation { presentation = resolved }
    }

    private func confirm(_ title: String) {
        confirmation = title
        confirmationTask?.cancel()
        confirmationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(ActionPillContent.confirmationDuration))
            } catch {
                return
            }
            self?.clearConfirmation()
            self?.refresh()
        }
    }

    private func clearConfirmation() {
        confirmationTask?.cancel()
        confirmationTask = nil
        confirmation = nil
    }
}
