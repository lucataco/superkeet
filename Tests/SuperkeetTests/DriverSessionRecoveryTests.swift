import XCTest
@testable import Superkeet

@MainActor
final class DriverSessionRecoveryTests: XCTestCase {
    private func spec(_ name: String = "get_window_state") -> ActionToolSpec {
        ActionToolSpec(descriptor: MCPToolDescriptor(serverID: UUID(), serverName: "cua-driver", name: name,
            title: nil, description: nil, risk: .readOnly, inputSchemaJSON: #"{"properties":{"session":{"type":"string"}}}"#))
    }

    func testEndedSessionIsRevivedOnceAndTheExactCallIsRetried() async throws {
        let calls = OSAllocatedUnfairLockBox<[(UUID, String, String, Bool)]>([])
        let spec = spec()
        let router = ActionToolRouter(callTool: { server, name, arguments, structured in
            calls.mutate { $0.append((server, name, arguments, structured)) }
            if calls.value.count == 1 { throw MCPConnectionError.toolReportedError("session 'sk-test' has ended") }
            return "done"
        })
        let output = try await router.execute(spec: spec, argumentsJSON: #"{"session":"sk-test"}"#)
        XCTAssertEqual(output, "done")
        XCTAssertEqual(calls.value.map { $0.1 }, ["get_window_state", "start_session", "get_window_state"])
        XCTAssertTrue(calls.value.allSatisfy { $0.0 == spec.serverID })
        XCTAssertEqual(calls.value[1].2, #"{"session":"sk-test"}"#)
        XCTAssertEqual(calls.value[0].2, calls.value[2].2)
        XCTAssertEqual(calls.value[0].3, calls.value[2].3)
    }

    func testRetryAndRevivalFailuresStopWithoutLooping() async {
        for failRevival in [false, true] {
            let calls = OSAllocatedUnfairLockBox<[String]>([])
            let router = ActionToolRouter(callTool: { _, name, _, _ in
                calls.mutate { $0.append(name) }
                if name == "start_session", !failRevival { return "revived" }
                throw MCPConnectionError.toolReportedError("session 'implicit-1' has ended")
            })
            do {
                _ = try await router.execute(spec: spec(), argumentsJSON: "{}")
                XCTFail("Expected the recovery failure")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("has ended"))
            }
            XCTAssertEqual(calls.value, failRevival ? ["get_window_state", "start_session"] : ["get_window_state", "start_session", "get_window_state"])
        }
    }

    func testOtherFailuresAndSessionStartsAreNotRetried() async {
        for (name, message) in [("get_window_state", "window is not live"), ("start_session", "session 'sk-test' has ended")] {
            let calls = OSAllocatedUnfairLockBox<Int>(0)
            let router = ActionToolRouter(callTool: { _, _, _, _ in
                calls.mutate { $0 += 1 }
                throw MCPConnectionError.toolReportedError(message)
            })
            do {
                _ = try await router.execute(spec: spec(name), argumentsJSON: "{}")
                XCTFail("Expected failure")
            } catch { XCTAssertTrue(error.localizedDescription.contains(message)) }
            XCTAssertEqual(calls.value, 1)
        }
    }
}
