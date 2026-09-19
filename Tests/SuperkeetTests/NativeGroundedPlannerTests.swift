import XCTest
@testable import Superkeet

@MainActor
final class NativeGroundedPlannerTests: XCTestCase {
    actor Chooser: ActionChoosing {
        var selections: [String]
        private(set) var requests: [ChoiceRequest] = []
        init(_ selections: [String] = ["a0"]) { self.selections = selections }
        func choose(_ request: ChoiceRequest) async throws -> ChoiceResponse {
            requests.append(request)
            let selected = selections.isEmpty ? "a0" : selections.removeFirst()
            return ChoiceResponse(selectedID: selected, model: "fixture", confidence: 1,
                                  probabilities: Dictionary(uniqueKeysWithValues: request.candidates.map { ($0.id, $0.id == selected ? 1 : 0) }))
        }
    }

    actor Driver {
        private(set) var calls: [(ActionToolSpec, String)] = []
        private var observations = 0
        private var value = ""
        let failure: ActionExecutionError?
        let verificationFails: Bool
        init(failure: ActionExecutionError? = nil, verificationFails: Bool = false) {
            self.failure = failure
            self.verificationFails = verificationFails
        }
        func execute(_ spec: ActionToolSpec, _ json: String) throws -> String {
            calls.append((spec, json))
            switch spec.toolName {
            case "list_windows": return NativeGroundingFixture.windows
            case "get_window_state":
                observations += 1
                if verificationFails && observations > 1 { throw ActionExecutionError.timedOut }
                return try NativeGroundingFixture.snapshot(observations, value: value)
            default:
                if let failure { throw failure }
                if spec.toolName == "set_value" { value = try NativeGroundingJSON.object(json)["value"] as? String ?? "" }
                return #"{"effect":"confirmed"}"#
            }
        }
    }

    final class Planner: ActionPlanning {
        var invoked = false
        var helperCalls = 0
        var tools: [ActionToolSpec] = []
        func run(task: String, tools: [ActionToolSpec], maxSteps: Int,
                 execute: @escaping @Sendable (ActionToolSpec, String) async throws -> String,
                 onEvent: @escaping @Sendable (ActionPlanEvent) -> Void) async throws -> String {
            invoked = true
            self.tools = tools
            for _ in 0..<helperCalls {
                let helper = try XCTUnwrap(tools.first(where: { $0.toolName == "superkeet_native_click" }))
                _ = try await execute(helper, #"{"app":"Notes","target":"Save"}"#)
            }
            return "planned"
        }
    }

    private func run(_ task: String, chooser: Chooser = Chooser(), driver: Driver = Driver(), fallback: Planner = Planner()) async throws -> String {
        let planner = NativeGroundedActionPlanner(fallback: fallback, chooser: chooser)
        return try await planner.run(task: task, tools: NativeGroundingFixture.tools(), maxSteps: 12,
                                     execute: { try await driver.execute($0, $1) }, onEvent: { _ in })
    }

    func testLiteralTextEntryExecutesOnceAndVerifiesFreshReadback() async throws {
        let driver = Driver()
        let chooser = Chooser()
        let fallback = Planner()
        let output = try await run(#"Type "Hello" into Title in Notes"#, chooser: chooser, driver: driver, fallback: fallback)
        XCTAssertTrue(output.contains("verified"))
        XCTAssertFalse(fallback.invoked)
        let calls = await driver.calls
        XCTAssertEqual(calls.map { $0.0.toolName }, ["list_windows", "get_window_state", "set_value", "get_window_state"])
        XCTAssertTrue(calls.filter { $0.0.toolName == "get_window_state" }.allSatisfy { $0.0.nativeObservation })
        XCTAssertNotNil(calls[2].0.nativePreflight)
        XCTAssertNotNil(calls[2].0.groundingDecision)
        XCTAssertTrue(calls[2].0.approvalSummary?.contains("Title") == true)
        let sessions = try calls.dropFirst().map { try NativeGroundingJSON.object($0.1)["session"] as? String }
        XCTAssertEqual(Set(sessions).count, 1)
        let requests = await chooser.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertFalse(String(data: try requests[0].encoded(), encoding: .utf8)?.contains("element_token") == true)
    }

    func testClickDoesNotClaimSuccessFromActionResponse() async throws {
        let driver = Driver()
        let output = try await run("Click Save in Notes", driver: driver)
        XCTAssertTrue(output.contains("could not be independently verified"))
        let calls = await driver.calls
        XCTAssertEqual(calls.filter { $0.0.toolName == "click" }.count, 1)
        XCTAssertEqual(calls.last?.0.toolName, "get_window_state")
    }

    func testReobserveRebuildsTableAndNeverReusesCapabilities() async throws {
        let chooser = Chooser(["reobserve", "a0"])
        let driver = Driver()
        _ = try await run("Click Save in Notes", chooser: chooser, driver: driver)
        let requests = await chooser.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertNotEqual(requests[0].captureID, requests[1].captureID)
        XCTAssertEqual(requests[1].history.first?.selectedID, "reobserve")
        let calls = await driver.calls
        let click = try XCTUnwrap(calls.first(where: { $0.0.toolName == "click" }))
        XCTAssertEqual(try NativeGroundingJSON.object(click.1)["element_token"] as? String, "s00000002:2")
    }

    func testReservedChoicesStopWithoutMutationOrFallback() async throws {
        for choices in [["abstain"], ["reobserve", "reobserve"]] {
            let driver = Driver()
            let fallback = Planner()
            _ = try await run("Click Save in Notes", chooser: Chooser(choices), driver: driver, fallback: fallback)
            let calls = await driver.calls
            XCTAssertTrue(calls.allSatisfy { $0.0.risk == .readOnly })
            XCTAssertFalse(fallback.invoked)
        }
    }

    func testUnknownCandidateDoesNotExecuteOrFallback() async throws {
        let driver = Driver()
        let fallback = Planner()
        do {
            _ = try await run("Click Save in Notes", chooser: Chooser(["invented"]), driver: driver, fallback: fallback)
            XCTFail("Expected invalid choice")
        } catch { XCTAssertTrue(error is ActionChoiceError) }
        let calls = await driver.calls
        XCTAssertTrue(calls.allSatisfy { $0.0.risk == .readOnly })
        XCTAssertFalse(fallback.invoked)
    }

    func testApprovalDenialAndAmbiguousDispatchFailureNeverRetry() async throws {
        for failure in [ActionExecutionError.approvalDenied("click"), .timedOut, .cancelled] {
            let driver = Driver(failure: failure)
            let fallback = Planner()
            do {
                _ = try await run("Click Save in Notes", driver: driver, fallback: fallback)
                XCTFail("Expected failure")
            } catch { XCTAssertEqual(error as? ActionExecutionError, failure) }
            let calls = await driver.calls
            XCTAssertEqual(calls.filter { $0.0.toolName == "click" }.count, 1)
            XCTAssertFalse(fallback.invoked)
        }
    }

    func testFailedPostObservationStopsWithoutRetry() async throws {
        let driver = Driver(verificationFails: true)
        let output = try await run(#"Type "Hello" into Title in Notes"#, driver: driver)
        XCTAssertTrue(output.contains("Stopped without retrying"))
        let calls = await driver.calls
        XCTAssertEqual(calls.filter { $0.0.toolName == "set_value" }.count, 1)
    }

    func testBroaderTasksUseApplePlannerWithGroundedHelpers() async throws {
        let fallback = Planner()
        let output = try await run("Organize my work in Notes", fallback: fallback)
        XCTAssertEqual(output, "planned")
        XCTAssertTrue(fallback.invoked)
        XCTAssertTrue(fallback.tools.contains { $0.toolName == "superkeet_native_click" })
        XCTAssertFalse(fallback.tools.contains { ["click", "set_value", "type_text"].contains($0.toolName) })
    }

    func testPlannerCannotRepeatUnknownGroundedAction() async throws {
        let fallback = Planner()
        fallback.helperCalls = 2
        let driver = Driver()
        do {
            _ = try await run("Save my work", driver: driver, fallback: fallback)
            XCTFail("Expected stopped step")
        } catch { XCTAssertTrue(error is ActionChoiceError) }
        let calls = await driver.calls
        XCTAssertEqual(calls.filter { $0.0.toolName == "click" }.count, 1)
    }

    func testPlannerCannotReplaceUnknownOutcomeWithSuccessSummary() async throws {
        let fallback = Planner()
        fallback.helperCalls = 1
        let output = try await run("Save my work", fallback: fallback)
        XCTAssertTrue(output.contains("could not be independently verified"))
        XCTAssertNotEqual(output, "planned")
    }

    func testIncompatibleDriverDoesNotExposeUngroundedNativeMutations() async throws {
        let fallback = Planner()
        let planner = NativeGroundedActionPlanner(fallback: fallback, chooser: Chooser())
        let partial = try NativeGroundingFixture.tools().filter { $0.toolName != "get_window_state" }
        _ = try await planner.run(task: "Save my work", tools: partial, maxSteps: 12, execute: { _, _ in "unused" }, onEvent: { _ in })
        XCTAssertTrue(fallback.invoked)
        XCTAssertFalse(fallback.tools.contains { NativeGroundingTools.isNativeMutation($0) })
    }

    func testKnownNonGroundingIntentsDelegateWithUntouchedTools() async throws {
        let tools = try NativeGroundingFixture.tools()
        for task in ["Open Discord", "Open Helium and go to youtube.com", "Search for cats", "Switch to Notes",
                     "Read the screen", "Press return", "Scroll down", "In the current tab, find DNS records",
                     "Navigate the current Chrome tab to example.com"] {
            let fallback = Planner()
            let chooser = Chooser()
            let planner = NativeGroundedActionPlanner(fallback: fallback, chooser: chooser)
            _ = try await planner.run(task: task, tools: tools, maxSteps: 12, execute: { _, _ in "unused" }, onEvent: { _ in })
            XCTAssertEqual(fallback.tools, tools, task)
            let requests = await chooser.requests
            XCTAssertTrue(requests.isEmpty, task)
        }
    }

    func testGroundingGateAlsoAppliesToIncompatibleDriver() async throws {
        let tools = try NativeGroundingFixture.tools().filter { $0.toolName != "get_window_state" }
        let fallback = Planner()
        let planner = NativeGroundedActionPlanner(fallback: fallback, chooser: Chooser())
        _ = try await planner.run(task: "Open Helium and search for cats", tools: tools, maxSteps: 12,
                                 execute: { _, _ in "unused" }, onEvent: { _ in })
        XCTAssertEqual(fallback.tools, tools)
    }
}
