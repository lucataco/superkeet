import Foundation

final class DebouncedStoreWriter<Snapshot: Sendable>: @unchecked Sendable {
    typealias SaveResult = Result<URL?, Error>

    private let queue: DispatchQueue
    private let delay: TimeInterval
    private let write: (Snapshot) throws -> URL?
    private let didSave: (SaveResult) -> Void
    private var pendingSave: DispatchWorkItem?
    private var revision = 0
    private var savedRevision = 0

    var hasUnsavedChanges: Bool { revision != savedRevision }

    init(
        queueLabel: String,
        delay: TimeInterval = 0.5,
        write: @escaping (Snapshot) throws -> URL?,
        didSave: @escaping (SaveResult) -> Void
    ) {
        queue = DispatchQueue(label: queueLabel, qos: .utility)
        self.delay = delay
        self.write = write
        self.didSave = didSave
    }

    func schedule(_ snapshot: Snapshot) {
        dispatchPrecondition(condition: .onQueue(.main))
        pendingSave?.cancel()
        revision += 1
        let version = revision
        let task = DispatchWorkItem { [weak self] in self?.enqueue(snapshot, revision: version) }
        pendingSave = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    func flush(_ snapshot: Snapshot) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard hasUnsavedChanges else { return }
        pendingSave?.cancel()
        pendingSave = nil
        revision += 1
        let result = queue.sync { Result { try write(snapshot) } }
        complete(result, revision: revision)
    }

    private func enqueue(_ snapshot: Snapshot, revision: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.write(snapshot) }
            DispatchQueue.main.async { self.complete(result, revision: revision) }
        }
    }

    private func complete(_ result: SaveResult, revision: Int) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard self.revision == revision else { return }
        if case .success = result { savedRevision = revision }
        didSave(result)
    }

    deinit { pendingSave?.cancel() }
}
