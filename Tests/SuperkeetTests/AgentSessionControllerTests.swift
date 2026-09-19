import XCTest
@testable import Superkeet

@MainActor
final class AgentSessionControllerTests: XCTestCase {

    final class FakeRouter: ActionRouting {
        var specs: [ActionToolSpec]
        var failure: Error?
        var preparationFailure: Error?
        /// Per-tool results; anything else returns "tool-output".
        var outputs: [String: String] = [:]
        /// Answer for plan cards; `nil` means "no HUD" (the protocol default, step by step).
        var planDecision: ActionPlanApprovalDecision?
        private(set) var executed: [String] = []
        private(set) var arguments: [String] = []
        private(set) var prepareCount = 0
        private(set) var plans: [ActionPlanApprovalRequest] = []

        init(specs: [ActionToolSpec], failure: Error? = nil) {
            self.specs = specs
            self.failure = failure
        }

        func prepareTools() async throws -> [ActionToolSpec] {
            prepareCount += 1
            if let preparationFailure { throw preparationFailure }
            return specs
        }

        func requestPlanApproval(_ plan: ActionPlanApprovalRequest) async -> ActionPlanApprovalDecision {
            plans.append(plan)
            return planDecision ?? .stepByStep
        }

        func execute(spec: ActionToolSpec, argumentsJSON: String) async throws -> String {
            executed.append(spec.toolName)
            arguments.append(argumentsJSON)
            if let failure { throw failure }
            return outputs[spec.toolName] ?? "tool-output"
        }
    }

    final class FakePlanner: ActionPlanning {
        let calls: Int
        let result: String
        let arguments: (Int) -> String
        private(set) var invoked = false
        private(set) var offeredTools: [ActionToolSpec] = []
        private(set) var tasks: [String] = []

        init(
            calls: Int = 1,
            result: String = "done",
            arguments: @escaping (Int) -> String = { "{\"n\":\($0)}" }
        ) {
            self.calls = calls
            self.result = result
            self.arguments = arguments
        }

        func run(
            task: String,
            tools: [ActionToolSpec],
            maxSteps: Int,
            execute: @escaping @Sendable (ActionToolSpec, String) async throws -> String,
            onEvent: @escaping @Sendable (ActionPlanEvent) -> Void
        ) async throws -> String {
            invoked = true
            offeredTools = tools
            tasks.append(task)
            let spec = tools.first { $0.serverID != NativeOpenAction.serverID } ?? tools[0]
            for index in 0..<calls {
                _ = try await execute(spec, arguments(index))
            }
            onEvent(.message(result))
            return result
        }
    }

    /// Calls named tools in a fixed order so cache behaviour across mixed
    /// read-only and mutating steps can be asserted.
    final class SequencePlanner: ActionPlanning {
        let sequence: [(tool: String, arguments: String)]
        private(set) var offeredTools: [ActionToolSpec] = []

        init(_ sequence: [(tool: String, arguments: String)]) {
            self.sequence = sequence
        }

        func run(
            task: String,
            tools: [ActionToolSpec],
            maxSteps: Int,
            execute: @escaping @Sendable (ActionToolSpec, String) async throws -> String,
            onEvent: @escaping @Sendable (ActionPlanEvent) -> Void
        ) async throws -> String {
            offeredTools = tools
            for step in sequence {
                guard let spec = tools.first(where: { $0.toolName == step.tool }) else {
                    throw ActionExecutionError.noTools
                }
                _ = try await execute(spec, step.arguments)
            }
            return "done"
        }
    }

    /// Records the context handed to each step and answers from a script.
    final class ContextualPlanner: ContextualActionPlanning {
        struct Call: Equatable {
            let task: String
            let context: ActionPlanContext?
        }

        private(set) var calls: [Call] = []
        var results: [String] = []

        func run(
            task: String, tools: [ActionToolSpec], maxSteps: Int,
            execute: @escaping @Sendable (ActionToolSpec, String) async throws -> String,
            onEvent: @escaping @Sendable (ActionPlanEvent) -> Void
        ) async throws -> String {
            calls.append(Call(task: task, context: nil))
            return results.isEmpty ? "planned \(task)" : results.removeFirst()
        }

        func run(
            step: ActionPlanStep, tools: [ActionToolSpec], maxSteps: Int,
            execute: @escaping @Sendable (ActionToolSpec, String) async throws -> String,
            onEvent: @escaping @Sendable (ActionPlanEvent) -> Void
        ) async throws -> String {
            calls.append(Call(task: step.task, context: step.context))
            return results.isEmpty ? "planned \(step.task)" : results.removeFirst()
        }
    }

    /// Never returns on its own; only cancellation ends it.
    final class HangingPlanner: ActionPlanning {
        private(set) var cancelled = false

        func run(
            task: String,
            tools: [ActionToolSpec],
            maxSteps: Int,
            execute: @escaping @Sendable (ActionToolSpec, String) async throws -> String,
            onEvent: @escaping @Sendable (ActionPlanEvent) -> Void
        ) async throws -> String {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                cancelled = true
                throw error
            }
            return "unreachable"
        }
    }

    private func makeSpec(name: String = "echo", risk: ActionToolRisk = .readOnly) -> ActionToolSpec {
        ActionToolSpec(descriptor: MCPToolDescriptor(
            serverID: UUID(),
            serverName: "test",
            name: name,
            title: nil,
            description: "Echo tool",
            risk: risk,
            inputSchemaJSON: "{}"
        ))
    }

    private func waitUntilFinished(_ controller: AgentSessionController, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while controller.phase.isActive && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testPhaseIsActiveOnlyWhilePlanningOrRunning() {
        XCTAssertTrue(AgentSessionController.Phase.planning.isActive)
        XCTAssertTrue(AgentSessionController.Phase.running.isActive)
        XCTAssertFalse(AgentSessionController.Phase.idle.isActive)
        XCTAssertFalse(AgentSessionController.Phase.finished("done").isActive)
        XCTAssertFalse(AgentSessionController.Phase.failed("nope").isActive)
        XCTAssertFalse(AgentSessionController.Phase.cancelled.isActive)
    }

    func testPhaseIsOutcomeOnlyWhenFinishedOrFailed() {
        XCTAssertTrue(AgentSessionController.Phase.finished("done").isOutcome)
        XCTAssertTrue(AgentSessionController.Phase.failed("nope").isOutcome)
        XCTAssertFalse(AgentSessionController.Phase.idle.isOutcome)
        XCTAssertFalse(AgentSessionController.Phase.planning.isOutcome)
        XCTAssertFalse(AgentSessionController.Phase.running.isOutcome)
        XCTAssertFalse(AgentSessionController.Phase.cancelled.isOutcome)
    }

    func testPhaseShowsHUDWhileWorkingAndOnOutcome() {
        XCTAssertTrue(AgentSessionController.Phase.planning.showsHUD)
        XCTAssertTrue(AgentSessionController.Phase.running.showsHUD)
        XCTAssertTrue(AgentSessionController.Phase.finished("done").showsHUD)
        XCTAssertTrue(AgentSessionController.Phase.failed("nope").showsHUD)
        XCTAssertFalse(AgentSessionController.Phase.idle.showsHUD)
        XCTAssertFalse(AgentSessionController.Phase.cancelled.showsHUD)
    }

    func testRunsCommandToCompletion() async {
        let router = FakeRouter(specs: [makeSpec()])
        let planner = FakePlanner(calls: 1)
        let controller = AgentSessionController(
            settings: .shared,
            router: router,
            plannerFactory: { planner }
        )

        controller.handleCommand("do the thing")
        await waitUntilFinished(controller)

        XCTAssertEqual(controller.phase, .finished("done"))
        XCTAssertEqual(router.executed, ["echo"])
        XCTAssertTrue(planner.invoked)
    }

    func testFailsWhenPlannerUnavailable() async {
        let router = FakeRouter(specs: [makeSpec()])
        let controller = AgentSessionController(
            settings: .shared,
            router: router,
            plannerFactory: { nil }
        )

        controller.handleCommand("do the thing")
        await waitUntilFinished(controller)

        XCTAssertEqual(controller.phase, .failed(ActionExecutionError.unavailable.localizedDescription))
    }

    func testNoEnabledServersSurfacesSetupHintForPlannerRequests() async {
        let router = FakeRouter(specs: [])
        router.preparationFailure = ActionExecutionError.noMCPServersEnabled
        let planner = FakePlanner(calls: 0)
        let controller = AgentSessionController(
            settings: .shared,
            router: router,
            plannerFactory: { planner }
        )

        controller.handleCommand("do the thing")
        await waitUntilFinished(controller)

        XCTAssertEqual(controller.phase, .failed(ActionExecutionError.noMCPServersEnabled.localizedDescription))
        XCTAssertFalse(planner.invoked)
        XCTAssertTrue(AppSettings.shared.runtimeIssue?.contains("No MCP servers are enabled") == true)
    }

    // MARK: Speculative launches

    private func fixtureResolver(_ name: String) -> URL? {
        let apps = ["Notes", "Discord"].map { URL(fileURLWithPath: "/fixture/Applications/\($0).app") }
        return AppResolver(directories: [URL(fileURLWithPath: "/fixture/Applications")], applicationsInDirectory: { _ in apps })
            .resolve(name)
    }

    private func speculativeLaunch(
        app: String = "Notes", launched: Bool = true, disagreement: Bool = false, delay: Duration = .zero
    ) -> SpeculativeLaunch {
        let url = URL(fileURLWithPath: "/fixture/Applications/\(app).app")
        let commit = SpeculativeCommit(
            action: .launch(SpeculativeApp(spokenName: app.lowercased(), url: url)),
            clause: "open \(app.lowercased())", sequence: 3, reason: .stable(count: 2)
        )
        return SpeculativeLaunch(commit: commit, disagreement: disagreement, outcome: Task {
            if delay > .zero { try? await Task.sleep(for: delay) }
            if launched {
                return .success(NativeLaunchedApp(name: app, bundleIdentifier: "com.fixture.\(app.lowercased())",
                                                  processIdentifier: 77, windowReady: true))
            }
            return .failure(NativeOpenActionError.openFailed("Launch refused"))
        })
    }

    func testSimpleOpenReusesTheSpeculativeLaunchInsteadOfOpeningAgain() async {
        let router = FakeRouter(specs: [])
        router.preparationFailure = ActionExecutionError.noMCPServersEnabled
        let controller = AgentSessionController(settings: .shared, router: router, plannerFactory: { nil },
                                                resolveApp: { [self] in fixtureResolver($0) })
        controller.handleCommand("open the notes app", speculative: speculativeLaunch(delay: .milliseconds(50)))
        await waitUntilFinished(controller)

        XCTAssertTrue(router.executed.isEmpty, "The app is already open; no second launch and no approval.")
        XCTAssertEqual(controller.phase, .finished("Opened Notes (pid 77, com.fixture.notes). Its window is on screen."))
        XCTAssertEqual(controller.activityLog.first, "Opened Notes while you were speaking")
        XCTAssertTrue(controller.activityLog.contains("Reused Open App"))
        XCTAssertEqual(controller.stepIndex, 0, "Reuse does not consume the step budget.")
    }

    func testPlannerOpenAppCallForTheSameAppIsReused() async {
        let router = FakeRouter(specs: [makeSpec()])
        let planner = SequencePlanner([("open_app", #"{"name":"Notes"}"#), ("echo", "{}")])
        let controller = AgentSessionController(settings: .shared, router: router, plannerFactory: { planner },
                                                resolveApp: { [self] in fixtureResolver($0) })
        controller.handleCommand("open the notes app and summarize my latest note", speculative: speculativeLaunch())
        await waitUntilFinished(controller)

        XCTAssertEqual(router.executed, ["echo"], "Only the step the launch did not cover runs.")
        XCTAssertEqual(controller.phase, .finished("done"))
        XCTAssertTrue(controller.activityLog.contains("Already done: Notes opened while you were speaking"))
        XCTAssertTrue(controller.activityLog.contains("Reused Open App"), "A planner call to open the same app is satisfied by the early launch.")
    }

    // MARK: Multi-step commands

    func testTargetCommandRunsAsTwoNativeStepsWithoutAnyPlanner() async throws {
        // "open the notes app and create a new note": open natively, then ⌘N in the app just opened.
        let router = FakeRouter(specs: [])
        router.preparationFailure = ActionExecutionError.noMCPServersEnabled
        router.outputs["open_app"] = NativeLaunchedApp(name: "Notes", bundleIdentifier: "com.apple.Notes", processIdentifier: 91, windowReady: true).summary
        router.outputs["press_shortcut"] = "Pressed ⌘N in Notes (pid 91)."
        var plannerCreated = false
        let controller = AgentSessionController(settings: .shared, router: router, plannerFactory: { plannerCreated = true; return nil },
                                                resolveApp: { [self] in fixtureResolver($0) })
        controller.handleCommand("open the notes app and create a new note")
        await waitUntilFinished(controller)

        XCTAssertEqual(router.executed, ["open_app", "press_shortcut"])
        XCTAssertEqual(try NativeOpenAction.decode(toolName: "press_shortcut", argumentsJSON: XCTUnwrap(router.arguments.last)),
                       .pressShortcut(app: "Notes", shortcut: try XCTUnwrap(KeyboardShortcut(keys: ["cmd", "n"]))))
        XCTAssertFalse(plannerCreated, "Both steps are deterministic; no model is needed.")
        XCTAssertEqual(router.prepareCount, 0)
        XCTAssertEqual(controller.phase, .finished("Opened Notes (pid 91, com.apple.Notes). Its window is on screen. Pressed ⌘N in Notes (pid 91)."))
        XCTAssertEqual(controller.activityLog.filter { $0.hasPrefix("Step ") }, ["Step 1 of 2: open the notes app", "Step 2 of 2: create a new note"])
        XCTAssertTrue(controller.activityLog.contains("Using ⌘N to create a new note in Notes"))
        XCTAssertEqual(controller.stepIndex, 2)
    }

    func testSpeculativeLaunchSkipsTheOpenStepAndTheShortcutGoesToThatApp() async throws {
        let router = FakeRouter(specs: [])
        router.preparationFailure = ActionExecutionError.noMCPServersEnabled
        let controller = AgentSessionController(settings: .shared, router: router, plannerFactory: { nil },
                                                resolveApp: { [self] in fixtureResolver($0) })
        controller.handleCommand("open the notes app and create a new note", speculative: speculativeLaunch())
        await waitUntilFinished(controller)

        XCTAssertEqual(router.executed, ["press_shortcut"], "The open step already happened while the user was speaking.")
        XCTAssertEqual(try NativeOpenAction.decode(toolName: "press_shortcut", argumentsJSON: XCTUnwrap(router.arguments.first)),
                       .pressShortcut(app: "Notes", shortcut: try XCTUnwrap(KeyboardShortcut(keys: ["cmd", "n"]))))
        XCTAssertEqual(controller.phase, .finished("tool-output"))
        XCTAssertEqual(controller.activityLog.first, "Opened Notes while you were speaking")
        XCTAssertTrue(controller.activityLog.contains("Already done: Notes opened while you were speaking"))
    }

    func testNamedRecipeTargetMustBeInstalledAndRunning() async throws {
        let notes = URL(fileURLWithPath: "/fixture/Applications/Notes.app")
        for running in [true, false] {
            let router = FakeRouter(specs: [makeSpec()])
            let planner = ContextualPlanner()
            let controller = AgentSessionController(settings: .shared, router: router, plannerFactory: { planner },
                                                    resolveApp: { [self] in fixtureResolver($0) }, isAppRunning: { $0 == notes && running })
            controller.handleCommand("create a new note in Notes")
            await waitUntilFinished(controller)
            if running {
                XCTAssertEqual(router.executed, ["press_shortcut"])
                XCTAssertTrue(planner.calls.isEmpty, "A running named app takes the shortcut directly.")
            } else {
                XCTAssertTrue(router.executed.isEmpty)
                XCTAssertEqual(planner.calls.map(\.task), ["create a new note in Notes"], "A stopped app is left to the planner.")
            }
        }
    }

    func testLaterStepsReceiveWhatEarlierStepsDid() async throws {
        let router = FakeRouter(specs: [makeSpec()])
        router.outputs["open_app"] = NativeLaunchedApp(name: "Notes", bundleIdentifier: "com.apple.Notes", processIdentifier: 91, windowReady: false).summary
        let planner = ContextualPlanner()
        planner.results = ["Summarized the note."]
        let controller = AgentSessionController(settings: .shared, router: router, plannerFactory: { planner },
                                                resolveApp: { [self] in fixtureResolver($0) })
        controller.handleCommand("open the notes app, then summarize my latest note")
        await waitUntilFinished(controller)

        XCTAssertEqual(router.executed, ["open_app"])
        XCTAssertEqual(planner.calls.count, 1)
        let call = try XCTUnwrap(planner.calls.first)
        XCTAssertEqual(call.task, "summarize my latest note", "The planner sees only its own step.")
        let context = try XCTUnwrap(call.context, "A contextual planner receives the carried context.")
        XCTAssertEqual(context.command, "open the notes app, then summarize my latest note")
        XCTAssertEqual(context.stepNumber, 2)
        XCTAssertEqual(context.stepCount, 2)
        XCTAssertEqual(context.completed.map(\.clause), ["open the notes app"])
        XCTAssertEqual(context.currentApp?.processIdentifier, 91)
        XCTAssertEqual(context.currentApp?.windowReady, false)
        XCTAssertTrue(context.instructions(for: call.task).contains("Notes is already open (pid 91"))
        XCTAssertEqual(controller.phase, .finished("Opened Notes (pid 91, com.apple.Notes). No window has appeared yet. Summarized the note."))
    }

    func testPlannerOpenedAppsFlowIntoLaterStepContext() async throws {
        // Step 1 is planned (the model opens Pages); step 2's recipe targets Pages.
        let router = FakeRouter(specs: [makeSpec()])
        router.outputs["open_app"] = NativeLaunchedApp(name: "Pages", bundleIdentifier: nil, processIdentifier: 5, windowReady: true).summary
        let planner = SequencePlanner([("open_app", #"{"name":"Pages"}"#)])
        let controller = AgentSessionController(settings: .shared, router: router, plannerFactory: { planner },
                                                resolveApp: { [self] in fixtureResolver($0) })
        controller.handleCommand("start writing my essay and then save it")
        await waitUntilFinished(controller)
        XCTAssertEqual(router.executed, ["open_app", "press_shortcut"])
        XCTAssertEqual(try NativeOpenAction.decode(toolName: "press_shortcut", argumentsJSON: XCTUnwrap(router.arguments.last)),
                       .pressShortcut(app: "Pages", shortcut: try XCTUnwrap(KeyboardShortcut(keys: ["cmd", "s"]))))
    }

    func testURLStepUsesTheBrowserOpenedByAnEarlierStep() async throws {
        let router = FakeRouter(specs: [makeSpec()])
        router.outputs["open_app"] = NativeLaunchedApp(name: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 3, windowReady: true).summary
        let planner = ContextualPlanner()
        let controller = AgentSessionController(settings: .shared, router: router, plannerFactory: { planner },
                                                resolveApp: { name in
                                                    let apps = ["Safari"].map { URL(fileURLWithPath: "/fixture/Applications/\($0).app") }
                                                    return AppResolver(directories: [URL(fileURLWithPath: "/fixture/Applications")],
                                                                       applicationsInDirectory: { _ in apps }).resolve(name)
                                                })
        controller.handleCommand("open Safari, go to youtube.com, and search for cats")
        await waitUntilFinished(controller)
        XCTAssertEqual(router.executed, ["open_app", "open_url"])
        XCTAssertEqual(try NativeOpenAction.decode(toolName: "open_url", argumentsJSON: XCTUnwrap(router.arguments.last)),
                       .openURL(url: try XCTUnwrap(URL(string: "https://youtube.com")), browser: "Safari"))
        XCTAssertEqual(planner.calls.map(\.task), ["search for cats"])
        XCTAssertEqual(planner.calls.first?.context?.completed.count, 2)
    }

    func testAStepFailureStopsTheCommandAndKeepsEarlierEffects() async {
        let router = FakeRouter(specs: [makeSpec()])
        router.outputs["open_app"] = NativeLaunchedApp(name: "Notes", bundleIdentifier: nil, processIdentifier: 1, windowReady: true).summary
        // Step 2 (⌘N) is denied at the approval gate; step 3 must never start.
        let denying = DenyingRouter(after: 1, wrapping: router)
        var plannerCreated = 0
        let controller = AgentSessionController(settings: .shared, router: denying, plannerFactory: { plannerCreated += 1; return ContextualPlanner() },
                                                resolveApp: { [self] in fixtureResolver($0) })
        controller.handleCommand("open the notes app and create a new note and summarize it")
        await waitUntilFinished(controller)
        XCTAssertEqual(denying.executed, ["open_app", "press_shortcut"], "Nothing after the denied step runs.")
        if case .failed(let message) = controller.phase {
            XCTAssertTrue(message.contains("not approved"), message)
        } else {
            XCTFail("Expected denial, got \(controller.phase)")
        }
        XCTAssertEqual(plannerCreated, 0, "The planner was never needed before the failure.")
    }

    /// Denies every execution after the first N.
    final class DenyingRouter: ActionRouting {
        let after: Int
        let wrapped: FakeRouter
        private(set) var executed: [String] = []
        init(after: Int, wrapping: FakeRouter) { self.after = after; wrapped = wrapping }
        func prepareTools() async throws -> [ActionToolSpec] { try await wrapped.prepareTools() }
        func execute(spec: ActionToolSpec, argumentsJSON: String) async throws -> String {
            executed.append(spec.toolName)
            if executed.count > after { throw ActionExecutionError.approvalDenied(spec.displayName) }
            return try await wrapped.execute(spec: spec, argumentsJSON: argumentsJSON)
        }
    }

    func testCompactObservationsReachThePlannerProjectedAndRankedByTheStep() async throws {
        var observe = makeSpec(name: "get_window_state")
        observe.compactObservation = true
        observe.requiresFreshObservation = true
        let router = FakeRouter(specs: [observe])
        router.outputs["get_window_state"] = #"""
        {"app_name":"Notes","window_title":"Notes","snapshot_id":"s00000009","elements":[
          {"element_index":0,"role":"AXWindow","label":"Notes","depth":0},
          {"element_index":1,"role":"AXButton","label":"Toggle sidebar","parent_index":0,"actions":["AXPress"],"enabled":true},
          {"element_index":2,"role":"AXButton","label":"New Note","parent_index":0,"actions":["AXPress"],"enabled":true},
          {"element_index":3,"role":"AXTextArea","label":"","value":"line one\nline two","parent_index":0}
        ]}
        """#
        /// Captures what the planner is handed back from a tool call.
        final class RecordingPlanner: ActionPlanning {
            var seen: [String] = []
            func run(task: String, tools: [ActionToolSpec], maxSteps: Int,
                     execute: @escaping @Sendable (ActionToolSpec, String) async throws -> String,
                     onEvent: @escaping @Sendable (ActionPlanEvent) -> Void) async throws -> String {
                let spec = try XCTUnwrap(tools.first { $0.toolName == "get_window_state" })
                seen.append(try await execute(spec, #"{"pid":1,"window_id":2}"#))
                return "done"
            }
        }
        let planner = RecordingPlanner()
        let controller = AgentSessionController(settings: .shared, router: router, plannerFactory: { planner })
        controller.handleCommand("make a new note in the window that is open")
        await waitUntilFinished(controller)

        let projected = try XCTUnwrap(planner.seen.first)
        let lines = projected.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "Notes (snapshot s00000009, 4 elements; use element_index or element_token)")
        XCTAssertEqual(lines[1], "[2] Button “New Note”", "The step's words rank the matching control first.")
        XCTAssertEqual(lines[2], "[1] Button “Toggle sidebar”")
        XCTAssertEqual(lines[3], "[3] TextArea = (17 characters)")
        XCTAssertFalse(projected.contains("line one"))
    }

    func testNonJSONObservationResultsAreTruncatedNotDropped() async throws {
        var observe = makeSpec(name: "get_window_state")
        observe.compactObservation = true
        let router = FakeRouter(specs: [observe])
        router.outputs["get_window_state"] = String(repeating: "markdown ", count: 200)
        let planner = SequencePlanner([("get_window_state", "{}")])
        let controller = AgentSessionController(settings: .shared, router: router, plannerFactory: { planner })
        controller.handleCommand("look")
        await waitUntilFinished(controller)
        let logged = try XCTUnwrap(controller.activityLog.first { $0.hasPrefix("Finished") })
        XCTAssertTrue(logged.hasPrefix("Finished"))
        XCTAssertEqual(controller.phase, .finished("done"))
    }

    // MARK: Plan approval

    private func withPolicy(_ policy: ActionApprovalPolicy, _ body: () async throws -> Void) async rethrows {
        let original = AppSettings.shared.actionApprovalPolicy
        AppSettings.shared.actionApprovalPolicy = policy
        defer { AppSettings.shared.actionApprovalPolicy = original }
        try await body()
    }

    func testCompoundCommandShowsOnePlanCardDescribingEveryStep() async throws {
        try await withPolicy(.readOnlyAuto) {
            let router = FakeRouter(specs: [makeSpec()])
            router.outputs["open_app"] = NativeLaunchedApp(name: "Notes", bundleIdentifier: nil, processIdentifier: 91, windowReady: true).summary
            router.planDecision = .stepByStep
            let planner = ContextualPlanner()
            let controller = AgentSessionController(settings: .shared, router: router, plannerFactory: { planner },
                                                    resolveApp: { [self] in fixtureResolver($0) })
            controller.handleCommand("open the notes app, create a new note, and summarize my day")
            await waitUntilFinished(controller)

            XCTAssertEqual(router.plans.count, 1)
            let plan = try XCTUnwrap(router.plans.first)
            XCTAssertEqual(plan.command, "open the notes app, create a new note, and summarize my day")
            XCTAssertEqual(plan.steps.map(\.summary), ["Open the notes app", "Press ⌘N in Notes", "Planned on-device; each tool call asks as usual"])
            XCTAssertEqual(plan.steps.map(\.text), ["open the notes app", "create a new note", "summarize my day"])
            XCTAssertEqual(plan.steps[1].risk, .mutating)
            XCTAssertEqual(plan.steps[2].route, .planned)
            XCTAssertTrue(plan.hasPlannedSteps)
            XCTAssertEqual(controller.activityLog.first, "Plan will ask for each step")
            XCTAssertEqual(router.executed, ["open_app", "press_shortcut"])
            XCTAssertEqual(planner.calls.map(\.task), ["summarize my day"])
        }
    }

    func testPlanCardPredictsTheShortcutTargetFromTheAppTheOpenStepWillOpen() async throws {
        try await withPolicy(.readOnlyAuto) {
            let router = FakeRouter(specs: [])
            router.preparationFailure = ActionExecutionError.noMCPServersEnabled
            router.planDecision = .approveAll
            let controller = AgentSessionController(settings: .shared, router: router, plannerFactory: { nil },
                                                    resolveApp: { [self] in fixtureResolver($0) })
            controller.handleCommand("open Discord and save it")
            await waitUntilFinished(controller)
            let plan = try XCTUnwrap(router.plans.first)
            XCTAssertEqual(plan.steps.map(\.summary), ["Open Discord", "Press ⌘S in Discord"],
                           "Before anything runs, the card already knows step 2 acts in the app step 1 opens.")
            XCTAssertEqual(plan.grants.count, 2)
            XCTAssertEqual(controller.activityLog.first, "Plan approved")
        }
    }

    func testDeniedPlanRunsNothingAndReportsIt() async throws {
        await withPolicy(.readOnlyAuto) {
            let router = FakeRouter(specs: [makeSpec()])
            router.planDecision = .deny
            let planner = ContextualPlanner()
            let controller = AgentSessionController(settings: .shared, router: router, plannerFactory: { planner },
                                                    resolveApp: { [self] in fixtureResolver($0) })
            controller.handleCommand("open the notes app and create a new note")
            await waitUntilFinished(controller)
            XCTAssertEqual(router.plans.count, 1)
            XCTAssertTrue(router.executed.isEmpty)
            XCTAssertTrue(planner.calls.isEmpty)
            XCTAssertEqual(controller.phase, .failed(ActionExecutionError.planDenied.localizedDescription))
        }
    }

    func testPlanCardIsSkippedWhenNoPredictableStepWouldAsk() async throws {
        await withPolicy(.readOnlyAuto) {
            // Both steps are planned; nothing on the card could be pre-approved.
            let router = FakeRouter(specs: [makeSpec()])
            router.planDecision = .deny
            let planner = ContextualPlanner()
            let controller = AgentSessionController(settings: .shared, router: router, plannerFactory: { planner })
            controller.handleCommand("summarize my day and draft a reply")
            await waitUntilFinished(controller)
            XCTAssertTrue(router.plans.isEmpty, "A card with nothing to approve is just a delay.")
            XCTAssertEqual(planner.calls.map(\.task), ["summarize my day", "draft a reply"])
            XCTAssertEqual(controller.phase, .finished("planned summarize my day planned draft a reply"))
        }
    }

    func testSingleStepCommandsNeverShowAPlanCard() async throws {
        await withPolicy(.readOnlyAuto) {
            let router = FakeRouter(specs: [])
            router.planDecision = .deny
            let controller = AgentSessionController(settings: .shared, router: router, plannerFactory: { nil })
            controller.handleCommand("open Discord")
            await waitUntilFinished(controller)
            XCTAssertTrue(router.plans.isEmpty)
            XCTAssertEqual(router.executed, ["open_app"])
        }
    }

    func testSpeculativeLaunchAppearsOnThePlanCardAsAlreadyDone() async throws {
        try await withPolicy(.readOnlyAuto) {
            let router = FakeRouter(specs: [])
            router.preparationFailure = ActionExecutionError.noMCPServersEnabled
            router.planDecision = .approveAll
            let controller = AgentSessionController(settings: .shared, router: router, plannerFactory: { nil },
                                                    resolveApp: { [self] in fixtureResolver($0) })
            controller.handleCommand("open the notes app and create a new note", speculative: speculativeLaunch())
            await waitUntilFinished(controller)
            let plan = try XCTUnwrap(router.plans.first)
            XCTAssertEqual(plan.steps.map(\.route.isAlreadyDone), [true, false])
            XCTAssertEqual(plan.steps.first?.summary, "Already open: Notes (opened while you were speaking)")
            XCTAssertEqual(plan.steps.last?.summary, "Press ⌘N in Notes")
            XCTAssertEqual(plan.grants.count, 1, "Only the shortcut needs approval; the launch already happened.")
            XCTAssertEqual(router.executed, ["press_shortcut"])
        }
    }

    // MARK: Checklist

    func testChecklistTracksStepsToolsAndTheEarlyLaunch() async throws {
        await withPolicy(.readOnlyAuto) {
            let router = FakeRouter(specs: [])
            router.preparationFailure = ActionExecutionError.noMCPServersEnabled
            router.planDecision = .approveAll
            let controller = AgentSessionController(settings: .shared, router: router, plannerFactory: { nil },
                                                    resolveApp: { [self] in fixtureResolver($0) })
            controller.handleCommand("open the notes app and create a new note", speculative: speculativeLaunch())
            await waitUntilFinished(controller)

            let items = controller.checklist.items
            XCTAssertEqual(items.map(\.kind), [
                .speculative, .step(number: 1, total: 2), .step(number: 2, total: 2), .note, .tool
            ])
            XCTAssertEqual(items.map(\.status), [.done, .skipped, .done, .info, .done])
            XCTAssertEqual(items[0].title, "Opened Notes while you were speaking")
            XCTAssertEqual(items[1].detail, "Already done while you were speaking")
            XCTAssertEqual(items[3].title, "Using ⌘N to create a new note in Notes")
            XCTAssertEqual(items[4].title, "Press Shortcut")
        }
    }

    func testChecklistMarksDeniedToolsAndUnfinishedStepsOnFailure() async {
        let router = FakeRouter(specs: [makeSpec()], failure: ActionExecutionError.approvalDenied("echo"))
        let planner = FakePlanner(calls: 1)
        let controller = AgentSessionController(settings: .shared, router: router, plannerFactory: { planner })
        controller.handleCommand("do the thing")
        await waitUntilFinished(controller)
        XCTAssertEqual(controller.checklist.items.map(\.status), [.denied])
        XCTAssertEqual(controller.checklist.items.first?.detail, "Not approved")

        let second = FakeRouter(specs: [makeSpec()], failure: ActionExecutionError.timedOut)
        let compound = AgentSessionController(settings: .shared, router: second, plannerFactory: { FakePlanner(calls: 1) })
        compound.handleCommand("look around and then report back")
        await waitUntilFinished(compound)
        XCTAssertEqual(compound.checklist.items.map(\.kind).first, .step(number: 1, total: 2))
        XCTAssertEqual(compound.checklist.items.map(\.status), [.failed, .failed], "The step that was running when the tool failed is marked failed too.")
        XCTAssertEqual(compound.checklist.items.count, 2, "Step 2 never started, so it has no row.")
    }

    func testResetClearsTheChecklist() async {
        let router = FakeRouter(specs: [makeSpec()])
        let controller = AgentSessionController(settings: .shared, router: router, plannerFactory: { FakePlanner(calls: 1) })
        controller.handleCommand("do the thing")
        await waitUntilFinished(controller)
        XCTAssertFalse(controller.checklist.isEmpty)
        controller.reset()
        XCTAssertTrue(controller.checklist.isEmpty)
    }

    func testSingleStepCommandsAreUnchangedByDecomposition() async {
        let router = FakeRouter(specs: [makeSpec()])
        let planner = ContextualPlanner()
        let controller = AgentSessionController(settings: .shared, router: router, plannerFactory: { planner })
        controller.handleCommand("summarize my latest note")
        await waitUntilFinished(controller)
        XCTAssertEqual(planner.calls.count, 1)
        XCTAssertNil(planner.calls.first?.context, "A single step has no context to pass; the plain planner entry point is used.")
        XCTAssertFalse(controller.activityLog.contains { $0.hasPrefix("Step ") })
        XCTAssertEqual(controller.phase, .finished("planned summarize my latest note"))
    }

    func testQuotedTextInAStepIsNotSplit() async {
        let router = FakeRouter(specs: [makeSpec()])
        let planner = ContextualPlanner()
        let controller = AgentSessionController(settings: .shared, router: router, plannerFactory: { planner })
        controller.handleCommand(#"type "milk, eggs, and bread" into Body in Notes"#)
        await waitUntilFinished(controller)
        XCTAssertEqual(planner.calls.map(\.task), [#"type "milk, eggs, and bread" into Body in Notes"#])
    }

    func testDifferentAppInTheFinalCommandIsOpenedNormally() async {
        let router = FakeRouter(specs: [])
        router.preparationFailure = ActionExecutionError.noMCPServersEnabled
        let controller = AgentSessionController(settings: .shared, router: router, plannerFactory: { nil },
                                                resolveApp: { [self] in fixtureResolver($0) })
        controller.handleCommand("open Discord", speculative: speculativeLaunch(app: "Notes", disagreement: true))
        await waitUntilFinished(controller)

        XCTAssertEqual(router.executed, ["open_app"], "Notes was opened early, but the command asks for Discord.")
        XCTAssertEqual(controller.phase, .finished("tool-output"))
        XCTAssertEqual(controller.activityLog.first, "Opened Notes while you were speaking")
        XCTAssertTrue(controller.activityLog.contains { $0.hasPrefix("Later speech named a different app") })
    }

    func testFailedSpeculativeLaunchIsReportedAndTheCommandOpensTheApp() async {
        let router = FakeRouter(specs: [])
        router.preparationFailure = ActionExecutionError.noMCPServersEnabled
        let controller = AgentSessionController(settings: .shared, router: router, plannerFactory: { nil },
                                                resolveApp: { [self] in fixtureResolver($0) })
        controller.handleCommand("open Notes", speculative: speculativeLaunch(launched: false))
        await waitUntilFinished(controller)

        XCTAssertEqual(router.executed, ["open_app"])
        XCTAssertEqual(controller.phase, .finished("tool-output"))
        XCTAssertTrue(controller.activityLog.first?.hasPrefix("Couldn't open Notes early: ") == true, controller.activityLog.first ?? "")
    }

    func testCancellingWhileWaitingForTheLaunchEndsTheRun() async {
        let router = FakeRouter(specs: [])
        let controller = AgentSessionController(settings: .shared, router: router, plannerFactory: { nil },
                                                resolveApp: { [self] in fixtureResolver($0) })
        controller.handleCommand("open Notes", speculative: speculativeLaunch(delay: .seconds(5)))
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(AppSettings.shared.actionStatusText, "Opening Notes…")
        controller.cancel()
        await waitUntilFinished(controller)
        XCTAssertEqual(controller.phase, .cancelled)
        XCTAssertTrue(router.executed.isEmpty)
    }

    func testCompoundOpenPlansWithBuiltInToolsWhenNoMCPInventory() async {
        for missing in [ActionExecutionError.noMCPServersEnabled, .noTools] {
            let router = FakeRouter(specs: [])
            router.preparationFailure = missing
            let planner = FakePlanner(calls: 0)
            // The open step's result is not a recognisable launch, so the recipe has
            // no target and the second step falls to the planner with native tools only.
            let controller = AgentSessionController(settings: .shared, router: router, plannerFactory: { planner },
                                                    resolveApp: { [self] in fixtureResolver($0) })
            controller.handleCommand("open the notes app and create a new note")
            await waitUntilFinished(controller)
            XCTAssertEqual(router.executed, ["open_app"], "\(missing)")
            XCTAssertTrue(planner.invoked, "\(missing)")
            XCTAssertEqual(planner.tasks, ["create a new note"])
            XCTAssertEqual(planner.offeredTools, NativeOpenAction.tools)
            XCTAssertEqual(router.prepareCount, 1)
            XCTAssertEqual(controller.phase, .finished("tool-output done"))
        }
    }

    func testRequestsWithoutAnOpenClauseStillReportMissingInventory() async {
        let router = FakeRouter(specs: [])
        router.preparationFailure = ActionExecutionError.noTools
        let planner = FakePlanner(calls: 0)
        let controller = AgentSessionController(settings: .shared, router: router, plannerFactory: { planner })
        controller.handleCommand("click Save in Notes and scroll down")
        await waitUntilFinished(controller)
        XCTAssertFalse(planner.invoked)
        XCTAssertEqual(controller.phase, .failed(ActionExecutionError.noTools.localizedDescription))
    }

    func testRunDeadlineStopsAStalledCommand() async {
        let settings = AppSettings.shared
        let original = settings.actionRunDeadlineSeconds
        settings.actionRunDeadlineSeconds = 1
        defer { settings.actionRunDeadlineSeconds = original }

        let router = FakeRouter(specs: [makeSpec()])
        let planner = HangingPlanner()
        let controller = AgentSessionController(settings: settings, router: router, plannerFactory: { planner })
        controller.handleCommand("stall forever")
        await waitUntilFinished(controller, timeout: 5)

        XCTAssertEqual(controller.phase, .failed(ActionExecutionError.runDeadlineExceeded(seconds: 1).localizedDescription))
        // The phase flips synchronously; the planner observes cancellation when its task resumes.
        let deadline = Date().addingTimeInterval(2)
        while !planner.cancelled && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(planner.cancelled, "The deadline must cancel the planner's work, not just flip the phase.")
        XCTAssertFalse(settings.isActionSessionActive)
        XCTAssertTrue(settings.runtimeIssue?.contains("did not finish within 1 seconds") == true)
    }

    func testDeadlineDoesNotFireAfterACompletedRun() async {
        let settings = AppSettings.shared
        let original = settings.actionRunDeadlineSeconds
        settings.actionRunDeadlineSeconds = 1
        defer { settings.actionRunDeadlineSeconds = original }

        let router = FakeRouter(specs: [makeSpec()])
        let controller = AgentSessionController(settings: settings, router: router, plannerFactory: { FakePlanner(calls: 1) })
        controller.handleCommand("quick")
        await waitUntilFinished(controller)
        XCTAssertEqual(controller.phase, .finished("done"))
        try? await Task.sleep(for: .milliseconds(1_200))
        XCTAssertEqual(controller.phase, .finished("done"), "A finished run must not be relabelled as timed out later.")
    }

    func testEnforcesStepBudget() async {
        let settings = AppSettings.shared
        let original = settings.actionMaxSteps
        settings.actionMaxSteps = 2
        defer { settings.actionMaxSteps = original }

        let router = FakeRouter(specs: [makeSpec()])
        let planner = FakePlanner(calls: 3)
        let controller = AgentSessionController(
            settings: settings,
            router: router,
            plannerFactory: { planner }
        )

        controller.handleCommand("loop")
        await waitUntilFinished(controller)

        XCTAssertEqual(router.executed.count, 2)
        XCTAssertEqual(controller.stepTotal, 2)
        XCTAssertEqual(controller.stepIndex, 2)
        if case .failed(let message) = controller.phase {
            XCTAssertEqual(message, ActionExecutionError.stepBudgetExceeded.localizedDescription)
        } else {
            XCTFail("Expected step budget failure, got \(controller.phase)")
        }
    }

    func testReusesIdenticalToolCalls() async {
        let router = FakeRouter(specs: [makeSpec()])
        let planner = FakePlanner(calls: 2, arguments: { _ in "{}" })
        let controller = AgentSessionController(
            settings: .shared,
            router: router,
            plannerFactory: { planner }
        )

        controller.handleCommand("echo twice")
        await waitUntilFinished(controller)

        XCTAssertEqual(router.executed.count, 1, "Identical tool calls should be reused, not re-run.")
        XCTAssertEqual(controller.phase, .finished("done"))
        XCTAssertTrue(controller.activityLog.contains { $0.hasPrefix("Reused") })
    }

    func testApprovalDenialStopsExecution() async {
        let router = FakeRouter(specs: [makeSpec()], failure: ActionExecutionError.approvalDenied("echo"))
        let planner = FakePlanner(calls: 1)
        let controller = AgentSessionController(
            settings: .shared,
            router: router,
            plannerFactory: { planner }
        )

        controller.handleCommand("do the thing")
        await waitUntilFinished(controller)

        if case .failed(let message) = controller.phase {
            XCTAssertTrue(message.contains("not approved"))
        } else {
            XCTFail("Expected approval denial, got \(controller.phase)")
        }
    }

    func testSuccessfulMutationInvalidatesCachedReadOnlyResults() async {
        let router = FakeRouter(specs: [makeSpec(name: "list_windows"), makeSpec(name: "click", risk: .mutating)])
        let planner = SequencePlanner([("list_windows", "{}"), ("click", #"{"x":1}"#), ("list_windows", "{}")])
        let controller = AgentSessionController(settings: .shared, router: router, plannerFactory: { planner })
        controller.handleCommand("click the button while looking again")
        await waitUntilFinished(controller)
        XCTAssertEqual(router.executed, ["list_windows", "click", "list_windows"],
                       "A read-only result observed before a state change must not be reused after it.")
        XCTAssertEqual(controller.phase, .finished("done"))
        XCTAssertFalse(controller.activityLog.contains { $0.hasPrefix("Reused") })
    }

    func testReadOnlyResultsStayCachedWithoutInterveningMutation() async {
        let router = FakeRouter(specs: [makeSpec(name: "search"), makeSpec(name: "other")])
        let planner = SequencePlanner([("search", "{}"), ("other", "{}"), ("search", "{}")])
        let controller = AgentSessionController(settings: .shared, router: router, plannerFactory: { planner })
        controller.handleCommand("search twice")
        await waitUntilFinished(controller)
        XCTAssertEqual(router.executed, ["search", "other"])
        XCTAssertTrue(controller.activityLog.contains { $0.hasPrefix("Reused") })
    }

    func testMutationResultsRemainReusedAfterOtherMutations() async {
        let router = FakeRouter(specs: [makeSpec(name: "open_thing", risk: .mutating), makeSpec(name: "click", risk: .mutating)])
        let planner = SequencePlanner([("open_thing", #"{"name":"Notes"}"#), ("click", "{}"), ("open_thing", #"{"name":"Notes"}"#)])
        let controller = AgentSessionController(settings: .shared, router: router, plannerFactory: { planner })
        controller.handleCommand("repeat the same mutation")
        await waitUntilFinished(controller)
        XCTAssertEqual(router.executed, ["open_thing", "click"], "An identical mutation is reused, never repeated.")
        XCTAssertTrue(controller.activityLog.contains { $0.hasPrefix("Reused") })
    }

    func testFreshObservationsFromRouterBypassResultCache() async {
        var spec = makeSpec(name: "list_windows")
        spec.requiresFreshObservation = true
        let router = FakeRouter(specs: [spec])
        let planner = FakePlanner(calls: 2, arguments: { _ in "{}" })
        let controller = AgentSessionController(settings: .shared, router: router, plannerFactory: { planner })
        controller.handleCommand("look twice")
        await waitUntilFinished(controller)
        XCTAssertEqual(router.executed, ["list_windows", "list_windows"])
    }

    func testNativeObservationsBypassResultCache() async {
        var spec = makeSpec(name: "get_window_state")
        spec.nativeObservation = true
        let router = FakeRouter(specs: [spec])
        let planner = FakePlanner(calls: 2, arguments: { _ in "{}" })
        let controller = AgentSessionController(settings: .shared, router: router, plannerFactory: { planner })
        controller.handleCommand("observe twice")
        await waitUntilFinished(controller)
        XCTAssertEqual(router.executed, ["get_window_state", "get_window_state"])
        XCTAssertFalse(controller.activityLog.contains { $0.hasPrefix("Reused") })
    }

    func testActiveTabChromeObservationsBypassResultCache() async throws {
        let tools = ActionToolFilter.filtering(ActiveTabToolFixture.chrome(), task: "Find DNS records in the current tab")
        let snapshot = try XCTUnwrap(tools.first { $0.toolName == "take_snapshot" })
        let router = FakeRouter(specs: [snapshot])
        let planner = FakePlanner(calls: 2, arguments: { _ in #"{"pageId":7}"# })
        let controller = AgentSessionController(settings: .shared, router: router, plannerFactory: { planner })
        controller.handleCommand("Find DNS records in the current tab")
        await waitUntilFinished(controller)
        XCTAssertEqual(router.executed, ["take_snapshot", "take_snapshot"])
        XCTAssertFalse(controller.activityLog.contains { $0.hasPrefix("Reused") })
    }

    func testActiveTabNavigationReachesPlannerInsteadOfNativeOpen() async {
        let router = FakeRouter(specs: ActiveTabToolFixture.chrome())
        let planner = FakePlanner(calls: 0)
        let controller = AgentSessionController(settings: .shared, router: router, plannerFactory: { planner })
        controller.handleCommand("Open youtube.com in the current Chrome tab")
        await waitUntilFinished(controller)
        XCTAssertTrue(planner.invoked)
        XCTAssertEqual(router.prepareCount, 1)
        XCTAssertTrue(router.executed.isEmpty)
        XCTAssertEqual(controller.phase, .finished("done"))
    }

    func testPreflightObservationConsumesStepBudget() {
        let budget = AgentSessionController.StepBudget(limit: 3)
        XCTAssertTrue(budget.consume())
        XCTAssertTrue(budget.consume(count: 2))
        XCTAssertFalse(budget.consume())
        XCTAssertEqual(budget.used, 3)
    }

    func testSimpleOpenSkipsPlannerAndMCPPreparation() async throws {
        let examples = [
            ("open discord", NativeOpenAction.openApp(name: "discord")),
            ("open Helium and go to youtube.com", .openURL(url: try XCTUnwrap(URL(string: "https://youtube.com")), browser: "Helium"))
        ]
        for (command, expected) in examples {
            let router = FakeRouter(specs: [])
            router.preparationFailure = ActionExecutionError.noMCPServersEnabled
            var plannerCreated = false
            let controller = AgentSessionController(settings: .shared, router: router, plannerFactory: {
                plannerCreated = true
                return nil
            })
            controller.handleCommand(command)
            await waitUntilFinished(controller)
            XCTAssertEqual(controller.phase, .finished("tool-output"))
            XCTAssertEqual(router.executed, [expected.toolName])
            XCTAssertEqual(try NativeOpenAction.decode(toolName: expected.toolName, argumentsJSON: XCTUnwrap(router.arguments.first)), expected)
            XCTAssertEqual(router.prepareCount, 0)
            XCTAssertFalse(plannerCreated)
            XCTAssertEqual(controller.stepIndex, 1)
            XCTAssertTrue(controller.activityLog.contains("Running \(expected.spec.displayName)…"))
            XCTAssertTrue(controller.activityLog.contains("Finished \(expected.spec.displayName)"))
        }
    }

    func testCompoundOpenRunsTheOpenNativelyThenPlansTheRest() async {
        let router = FakeRouter(specs: [makeSpec()])
        let planner = FakePlanner(calls: 0)
        let controller = AgentSessionController(settings: .shared, router: router, plannerFactory: { planner })
        controller.handleCommand("open Helium and search for cats")
        await waitUntilFinished(controller)
        XCTAssertEqual(controller.phase, .finished("tool-output done"))
        XCTAssertEqual(router.executed, ["open_app"], "The open step is deterministic and runs before any planning.")
        XCTAssertTrue(planner.invoked)
        XCTAssertEqual(planner.tasks, ["search for cats"], "The planner receives only the step that needs it.")
        XCTAssertEqual(Array(planner.offeredTools.prefix(NativeOpenAction.tools.count)), NativeOpenAction.tools)
        XCTAssertEqual(router.prepareCount, 1)
    }

    func testMissingAppFallsThroughBeforeAnyOpenSideEffect() async {
        let router = FakeRouter(specs: [], failure: NativeOpenActionError.appNotFound("Missing"))
        let planner = FakePlanner(calls: 0)
        let controller = AgentSessionController(settings: .shared, router: router, plannerFactory: { planner })
        controller.handleCommand("open Missing")
        await waitUntilFinished(controller)
        XCTAssertEqual(router.executed, ["open_app"])
        XCTAssertEqual(router.prepareCount, 1)
        XCTAssertTrue(planner.invoked)
        XCTAssertEqual(Array(planner.offeredTools.prefix(NativeOpenAction.tools.count)), NativeOpenAction.tools)
        XCTAssertEqual(controller.phase, .finished("done"))
    }

    func testMissingAppInACompoundStepFallsThroughToThePlannerForThatStep() async {
        let router = FakeRouter(specs: [makeSpec()], failure: NativeOpenActionError.appNotFound("Missing"))
        let planner = FakePlanner(calls: 0)
        let controller = AgentSessionController(settings: .shared, router: router, plannerFactory: { planner })
        controller.handleCommand("open Missing and search for cats")
        await waitUntilFinished(controller)
        XCTAssertEqual(router.executed, ["open_app"], "The native attempt was a resolution miss, so nothing else ran natively.")
        XCTAssertEqual(planner.tasks, ["open Missing", "search for cats"])
        XCTAssertEqual(controller.phase, .finished("done done"))
    }

    func testMissingAppWithoutPlannerSurfacesResolutionError() async {
        let failure = NativeOpenActionError.appNotFound("Missing")
        let router = FakeRouter(specs: [], failure: failure)
        let controller = AgentSessionController(settings: .shared, router: router, plannerFactory: { nil })
        controller.handleCommand("open Missing")
        await waitUntilFinished(controller)
        XCTAssertEqual(controller.phase, .failed(failure.localizedDescription))
    }

    func testNativeOpenDenialCancellationAndDispatchErrorsNeverFallBack() async {
        let failures: [Error] = [ActionExecutionError.approvalDenied("Open App"), ActionExecutionError.cancelled,
                                 CancellationError(), ActionExecutionError.timedOut, NativeOpenActionError.openFailed("workspace failure")]
        for failure in failures {
            let router = FakeRouter(specs: [], failure: failure)
            let planner = FakePlanner(calls: 0)
            let controller = AgentSessionController(settings: .shared, router: router, plannerFactory: { planner })
            controller.handleCommand("open discord")
            await waitUntilFinished(controller)
            XCTAssertFalse(planner.invoked)
            XCTAssertEqual(router.prepareCount, 0)
            XCTAssertEqual(router.executed, ["open_app"])
            if failure is CancellationError || failure as? ActionExecutionError == .cancelled {
                XCTAssertEqual(controller.phase, .cancelled)
            } else {
                XCTAssertEqual(controller.phase, .failed(failure.localizedDescription))
            }
        }
    }
}
