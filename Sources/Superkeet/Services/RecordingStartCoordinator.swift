import Foundation

final class RecordingStartCoordinator {
    private(set) var requestID: UUID?

    func begin() -> UUID? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard requestID == nil else { return nil }
        let id = UUID()
        requestID = id
        return id
    }

    func cancel() {
        dispatchPrecondition(condition: .onQueue(.main))
        requestID = nil
    }

    func isCurrent(_ id: UUID) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        return requestID == id
    }

    @MainActor
    func run(
        _ id: UUID,
        prepare: @MainActor () async throws -> Void,
        start: @MainActor () async -> Bool
    ) async throws -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isCurrent(id) else { return false }
        try await prepare()
        guard isCurrent(id) else { return false }
        return await start()
    }
}
