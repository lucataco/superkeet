import XCTest
@testable import Superkeet

final class AsyncTimeoutTests: XCTestCase {
    private enum TestError: Error, Equatable {
        case timedOut
        case boom
    }

    func testReturnsOperationValue() async throws {
        let value = try await AsyncTimeout.run(seconds: 1, timeoutError: TestError.timedOut) {
            "ok"
        }
        XCTAssertEqual(value, "ok")
    }

    func testThrowsTimeoutWhenOperationExceedsDeadline() async {
        do {
            _ = try await AsyncTimeout.run(seconds: 0.1, timeoutError: TestError.timedOut) {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return "late"
            }
            XCTFail("Expected a timeout")
        } catch {
            XCTAssertEqual(error as? TestError, .timedOut)
        }
    }

    func testPropagatesOperationError() async {
        do {
            _ = try await AsyncTimeout.run(seconds: 1, timeoutError: TestError.timedOut) {
                throw TestError.boom
            }
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? TestError, .boom)
        }
    }

    func testTimeoutReturnsPromptly() async {
        let start = Date()
        _ = try? await AsyncTimeout.run(seconds: 0.2, timeoutError: TestError.timedOut) {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return "late"
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testParentCancellationThrowsCancellation() async {
        let task = Task {
            try await AsyncTimeout.run(seconds: 10, timeoutError: TestError.timedOut) {
                try await Task.sleep(nanoseconds: 20_000_000_000)
                return "late"
            }
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}
