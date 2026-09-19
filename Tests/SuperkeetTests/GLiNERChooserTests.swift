import XCTest
@testable import Superkeet

@MainActor
final class GLiNERChooserTests: XCTestCase {
    private let worker = #"""
    import json, os, sys, time
    if not sys.dont_write_bytecode:
        sys.exit(3)
    for line in sys.stdin:
        request = json.loads(line)
        goal = request["goal"]
        if goal == "timeout":
            time.sleep(10)
        if goal == "exit":
            sys.exit(1)
        if goal == "oversized":
            print("x" * 70000, flush=True)
            continue
        if goal == "malformed":
            print('{"error":"test"}', flush=True)
            continue
        if os.environ.get("SUPERKEET_GLINER_OFFLINE") != "1" or os.environ.get("HF_HUB_OFFLINE") != "1":
            sys.exit(2)
        selected = "abstain"
        response = {"schema":"cua.jev_choice_v1", "selected_id":selected,
                    "model":"lucataco/gliner2.5-cua-grounder-macos-v1", "confidence":1,
                    "probabilities":{c["id"]:float(c["id"] == selected) for c in request["candidates"]}}
        print(json.dumps(response), flush=True)
    """#

    private func request(_ goal: String = "valid") -> ChoiceRequest {
        ChoiceRequest(goal: goal, captureID: "test", regions: [], history: [],
                      candidates: ActionCandidate.reserved.map { .init(id: $0.id, description: $0.description) })
    }

    private func fixture() throws -> (GLiNERChooser, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".py")
        try worker.write(to: url, atomically: true, encoding: .utf8)
        let chooser = GLiNERChooser(python: "/usr/bin/python3", script: url.path,
                                    timing: .init(coldSeconds: 2, warmSeconds: 0.15, idleSeconds: 0.2, backoffSeconds: 0.05))
        return (chooser, url)
    }

    func testResidentWorkerWarmRequestsAndIdleUnload() async throws {
        let (chooser, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: file) }
        try await chooser.prepare()
        let response = try await chooser.choose(request())
        XCTAssertEqual(response.selectedID, "abstain")
        let loaded = await chooser.isLoaded
        XCTAssertTrue(loaded)
        try await Task.sleep(for: .milliseconds(350))
        let unloaded = await chooser.isLoaded
        XCTAssertFalse(unloaded)
        let restarted = try await chooser.choose(request())
        XCTAssertEqual(restarted.model, GLiNERChooser.model)
        await chooser.stop()
    }

    func testMalformedOversizedAndExitedWorkersAreDiscardedBeforeRestart() async throws {
        let (chooser, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: file) }
        for goal in ["malformed", "oversized", "exit"] {
            do { _ = try await chooser.choose(request(goal)); XCTFail("Expected worker failure") } catch { }
            let loaded = await chooser.isLoaded
            XCTAssertFalse(loaded)
            try await Task.sleep(for: .milliseconds(80))
            let response = try await chooser.choose(request())
            XCTAssertEqual(response.selectedID, "abstain")
        }
        await chooser.stop()
    }

    func testTimeoutAndCancellationDoNotLeakLateReplies() async throws {
        let (chooser, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: file) }
        try await chooser.prepare()
        do {
            _ = try await chooser.choose(request("timeout"))
            XCTFail("Expected deadline")
        } catch { XCTAssertEqual(error as? ActionExecutionError, .timedOut) }
        try await Task.sleep(for: .milliseconds(80))
        try await chooser.prepare()
        let request = request("timeout")
        let task = Task { try await chooser.choose(request) }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        try await Task.sleep(for: .milliseconds(80))
        let response = try await chooser.choose(self.request())
        XCTAssertEqual(response.selectedID, "abstain")
        await chooser.stop()
    }

    func testInstalledModelSmokeWhenRequested() async throws {
        guard let python = ProcessInfo.processInfo.environment["SUPERKEET_TEST_GROUNDER_PYTHON"] else {
            throw XCTSkip("Set SUPERKEET_TEST_GROUNDER_PYTHON to run the offline pinned-model smoke test")
        }
        let chooser = GLiNERChooser(python: python)
        try await chooser.prepare()
        let request = ChoiceRequest(goal: "Click Save.", captureID: "smoke", regions: [], history: [], candidates: [
            .init(id: "save", description: "Click button \"Save\""),
            .init(id: "cancel", description: "Click button \"Cancel\""),
            .init(id: "reobserve", description: ActionCandidate.reserved[0].description),
            .init(id: "abstain", description: ActionCandidate.reserved[1].description)
        ])
        let result = try await chooser.choose(request)
        await chooser.stop()
        XCTAssertEqual(result.model, GLiNERChooser.model)
        XCTAssertEqual(result.selectedID, "save")
    }

    func testShutdownInterruptsInflightTransport() async throws {
        let (chooser, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: file) }
        try await chooser.prepare()
        let request = request("timeout")
        let task = Task { try await chooser.choose(request) }
        try await Task.sleep(for: .milliseconds(30))
        await chooser.shutdown()
        do {
            _ = try await task.value
            XCTFail("Expected stopped transport")
        } catch { XCTAssertEqual(error as? ActionExecutionError, .cancelled) }
        let loaded = await chooser.isLoaded
        XCTAssertFalse(loaded)
    }
}
