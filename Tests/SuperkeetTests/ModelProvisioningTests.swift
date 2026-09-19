import XCTest
@testable import Superkeet

final class ModelProvisioningTests: XCTestCase {
    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testPhaseIgnoresDownloadProgressPayload() {
        // Views observe `phase` so a 670 MB download does not trigger a readiness probe per event.
        var early = ModelDownloadProgress()
        early.overallFraction = 0.1
        var late = ModelDownloadProgress()
        late.overallFraction = 0.9
        XCTAssertNotEqual(ModelProvisionState.downloading(early), ModelProvisionState.downloading(late))
        XCTAssertEqual(ModelProvisionState.downloading(early).phase, ModelProvisionState.downloading(late).phase)

        XCTAssertEqual(ModelProvisionState.failed("a").phase, ModelProvisionState.failed("b").phase)
        XCTAssertNotEqual(ModelProvisionState.downloading(early).phase, ModelProvisionState.installed.phase)
        XCTAssertNotEqual(ModelProvisionState.installed.phase, ModelProvisionState.failed("x").phase)
    }

    @MainActor
    func testBootstrapExceptionPublishesFailureAndRetryStartsFreshTask() async {
        var attempts = 0
        let service = ModelProvisioning(modelDirectory: directory(), prepareEngine: {
            attempts += 1
            throw ModelProvisioningError.message("Cargo unavailable: attempt \(attempts)")
        })
        for attempt in 1...2 {
            do {
                try await service.ensureModelAvailable()
                XCTFail("Expected bootstrap failure")
            } catch {
                XCTAssertEqual(service.state, .failed("Cargo unavailable: attempt \(attempt)"))
                XCTAssertFalse(service.state.isBusy)
                service.refreshInstalledState()
                XCTAssertEqual(service.state, .failed("Cargo unavailable: attempt \(attempt)"))
            }
        }
        XCTAssertEqual(attempts, 2)
    }

    @MainActor
    func testProcessLaunchExceptionIsVisibleAndCanBeRetriedSuccessfully() async throws {
        let url = directory()
        var launches = 0
        let service = ModelProvisioning(modelDirectory: url, prepareEngine: { "/usr/bin/true" }, download: { _, path in
            launches += 1
            if launches == 1 { throw ModelProvisioningError.message("Process launch failed") }
            for file in ["encoder-model.int8.onnx", "decoder_joint-model.int8.onnx", "vocab.txt", "config.json"] {
                try Data("fixture".utf8).write(to: URL(fileURLWithPath: path).appendingPathComponent(file))
            }
            return .init(exitCode: 0, errorMessage: nil)
        })
        do {
            try await service.ensureModelAvailable()
            XCTFail("Expected process launch failure")
        } catch {
            XCTAssertEqual(service.state, .failed("Process launch failed"))
            XCTAssertFalse(service.state.isBusy)
        }
        try await service.ensureModelAvailable()
        XCTAssertEqual(service.state, .installed)
        XCTAssertEqual(launches, 2)
    }

    @MainActor
    func testDirectoryPreparationFailureLeavesBusyState() async throws {
        let url = directory()
        try Data("not a directory".utf8).write(to: url)
        let service = ModelProvisioning(modelDirectory: url, prepareEngine: { "/usr/bin/true" })
        do {
            try await service.ensureModelAvailable()
            XCTFail("Expected directory preparation failure")
        } catch {
            guard case .failed = service.state else { return XCTFail("Expected failed state") }
            XCTAssertFalse(service.state.isBusy)
        }
    }

    @MainActor
    func testCancellationReturnsToNotInstalledRatherThanFailure() async {
        let service = ModelProvisioning(modelDirectory: directory(), prepareEngine: { throw CancellationError() })
        do {
            try await service.ensureModelAvailable()
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
            XCTAssertEqual(service.state, .notInstalled)
            XCTAssertFalse(service.state.isBusy)
        }
    }
}
