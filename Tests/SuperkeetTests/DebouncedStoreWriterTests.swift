import XCTest
@testable import Superkeet

final class DebouncedStoreWriterTests: XCTestCase {
    func testUntouchedWriterDoesNotWriteAndFailedFlushRemainsRetryable() {
        var attempts = 0
        var shouldFail = true
        let writer = DebouncedStoreWriter<String>(queueLabel: UUID().uuidString, delay: 60, write: { _ in
            attempts += 1
            if shouldFail { throw CocoaError(.fileWriteUnknown) }
            return nil
        }, didSave: { _ in })
        writer.flush("untouched")
        XCTAssertEqual(attempts, 0)
        writer.schedule("changed")
        writer.flush("changed")
        XCTAssertTrue(writer.hasUnsavedChanges)
        shouldFail = false
        writer.flush("changed")
        XCTAssertFalse(writer.hasUnsavedChanges)
        XCTAssertEqual(attempts, 2)
    }

    @MainActor
    func testFlushSupersedesOlderWriteCompletion() async {
        let entered = expectation(description: "Old asynchronous write entered")
        let release = DispatchSemaphore(value: 0)
        var writes: [String] = []
        var completions: [String] = []
        let writer = DebouncedStoreWriter<String>(queueLabel: UUID().uuidString, delay: 0, write: { snapshot in
            writes.append(snapshot)
            if snapshot == "old" {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 3)
            }
            return URL(fileURLWithPath: "/\(snapshot)")
        }, didSave: { result in
            if case .success(let url) = result { completions.append(url?.lastPathComponent ?? "none") }
        })
        writer.schedule("old")
        await fulfillment(of: [entered], timeout: 3)
        writer.schedule("new")
        release.signal()
        writer.flush("new")
        let drained = expectation(description: "Old completion drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 3)
        XCTAssertEqual(writes, ["old", "new"])
        XCTAssertEqual(completions, ["new"])
        XCTAssertFalse(writer.hasUnsavedChanges)
    }
}
