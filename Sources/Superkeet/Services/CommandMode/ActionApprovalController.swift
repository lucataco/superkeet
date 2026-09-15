import Foundation

@MainActor
final class ActionApprovalController: ObservableObject {
    static let shared = ActionApprovalController()

    @Published private(set) var pending: ActionApprovalRequest?

    private var continuation: CheckedContinuation<ActionApprovalDecision, Never>?

    func request(_ request: ActionApprovalRequest) async -> ActionApprovalDecision {
        if pending != nil {
            return .deny
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.pending = request
        }
    }

    func resolve(_ decision: ActionApprovalDecision) {
        guard let continuation else { return }
        self.continuation = nil
        pending = nil
        continuation.resume(returning: decision)
    }

    func cancelPending() {
        resolve(.deny)
    }
}
