import Foundation

@MainActor
final class ActionApprovalController: ObservableObject {
    static let shared = ActionApprovalController()

    @Published private(set) var pending: ActionApprovalRequest?
    @Published private(set) var pendingPlan: ActionPlanApprovalRequest?
    @Published private(set) var grants: Set<ActionApprovalGrant> = []

    private struct Entry {
        let request: ActionApprovalRequest
        let continuation: CheckedContinuation<ActionApprovalDecision, Never>
    }

    private struct PlanEntry {
        let request: ActionPlanApprovalRequest
        let continuation: CheckedContinuation<ActionPlanApprovalDecision, Never>
    }

    private var queue: [Entry] = []
    private var plan: PlanEntry?
    var pendingCount: Int { queue.count }

    func request(_ request: ActionApprovalRequest) async -> ActionApprovalDecision {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !Task.isCancelled else { return .deny }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .deny)
                    return
                }
                queue.append(Entry(request: request, continuation: continuation))
                if queue.count == 1 { pending = request }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(requestID: request.id) }
        }
    }

    func resolve(_ decision: ActionApprovalDecision, requestID: UUID? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let first = queue.first, requestID == nil || requestID == first.request.id else { return }
        queue.removeFirst()
        pending = queue.first?.request
        first.continuation.resume(returning: decision)
    }

    func approveSimilar(requestID: UUID? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let first = queue.first, requestID == nil || requestID == first.request.id else { return }
        if ActionApprovalGrant.supportsSimilar(first.request.tool, argumentsJSON: first.request.argumentsJSON) {
            grants.insert(.similar(to: first.request.tool, argumentsJSON: first.request.argumentsJSON))
        }
        resolve(.approve, requestID: first.request.id)
    }

    func requestPlan(_ request: ActionPlanApprovalRequest) async -> ActionPlanApprovalDecision {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !Task.isCancelled, plan == nil else { return .deny }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .deny)
                    return
                }
                plan = PlanEntry(request: request, continuation: continuation)
                pendingPlan = request
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelPlan(requestID: request.id) }
        }
    }

    func resolvePlan(_ decision: ActionPlanApprovalDecision, requestID: UUID? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let plan, requestID == nil || requestID == plan.request.id else { return }
        self.plan = nil
        pendingPlan = nil
        if decision == .approveAll {
            grants.formUnion(plan.request.grants)
        }
        plan.continuation.resume(returning: decision)
    }

    func grant(_ grant: ActionApprovalGrant) {
        dispatchPrecondition(condition: .onQueue(.main))
        grants.insert(grant)
    }

    func isGranted(_ spec: ActionToolSpec, argumentsJSON: String) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        return grants.contains { $0.covers(spec, argumentsJSON: argumentsJSON) }
    }

    func clearGrants() {
        dispatchPrecondition(condition: .onQueue(.main))
        grants.removeAll()
    }

    func cancelPending() {
        dispatchPrecondition(condition: .onQueue(.main))
        let entries = queue
        queue.removeAll()
        pending = nil
        for entry in entries { entry.continuation.resume(returning: .deny) }
        if let plan {
            self.plan = nil
            pendingPlan = nil
            plan.continuation.resume(returning: .deny)
        }
        grants.removeAll()
    }

    private func cancel(requestID: UUID) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let index = queue.firstIndex(where: { $0.request.id == requestID }) else { return }
        let entry = queue.remove(at: index)
        if index == 0 { pending = queue.first?.request }
        entry.continuation.resume(returning: .deny)
    }

    private func cancelPlan(requestID: UUID) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let plan, plan.request.id == requestID else { return }
        self.plan = nil
        pendingPlan = nil
        plan.continuation.resume(returning: .deny)
    }
}
