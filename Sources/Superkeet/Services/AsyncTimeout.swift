import Foundation

enum AsyncTimeout {
    static func run<T: Sendable>(
        seconds: Double,
        timeoutError: Error,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let coordinator = Coordinator<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                coordinator.start(
                    continuation: continuation,
                    seconds: seconds,
                    timeoutError: timeoutError,
                    operation: operation
                )
            }
        } onCancel: {
            coordinator.cancel()
        }
    }

    private final class Coordinator<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var operationTask: Task<Void, Never>?
        private var timeoutTask: Task<Void, Never>?
        private var finished = false

        func start(
            continuation: CheckedContinuation<T, Error>,
            seconds: Double,
            timeoutError: Error,
            operation: @escaping @Sendable () async throws -> T
        ) {
            lock.lock()
            guard !finished else {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            lock.unlock()

            let operationTask = Task {
                do {
                    let value = try await operation()
                    self.finish(.success(value))
                } catch {
                    self.finish(.failure(error))
                }
            }
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self.finish(.failure(timeoutError))
            }

            lock.lock()
            if finished {
                lock.unlock()
                operationTask.cancel()
                timeoutTask.cancel()
                return
            }
            self.operationTask = operationTask
            self.timeoutTask = timeoutTask
            lock.unlock()
        }

        func finish(_ result: Result<T, Error>) {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            let continuation = self.continuation
            self.continuation = nil
            let operationTask = self.operationTask
            let timeoutTask = self.timeoutTask
            self.operationTask = nil
            self.timeoutTask = nil
            lock.unlock()

            switch result {
            case .success(let value):
                continuation?.resume(returning: value)
            case .failure(let error):
                continuation?.resume(throwing: error)
            }

            operationTask?.cancel()
            timeoutTask?.cancel()
        }

        func cancel() {
            finish(.failure(CancellationError()))
        }
    }
}
