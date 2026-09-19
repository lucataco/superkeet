import Foundation

/// Keeps Foundation Models in charge of broader planning, exposing two small
/// single-step tools instead of asking the language model to invent AX handles.
final class NativeGroundedActionPlanner: ContextualActionPlanning {
    private let fallback: any ActionPlanning
    private let chooser: any ActionChoosing

    init(fallback: any ActionPlanning, chooser: any ActionChoosing = GLiNERChooser.shared) {
        self.fallback = fallback
        self.chooser = chooser
    }

    func run(
        task: String, tools: [ActionToolSpec], maxSteps: Int,
        execute: @escaping @Sendable (ActionToolSpec, String) async throws -> String,
        onEvent: @escaping @Sendable (ActionPlanEvent) -> Void
    ) async throws -> String {
        try await run(step: ActionPlanStep(task: task), tools: tools, maxSteps: maxSteps, execute: execute, onEvent: onEvent)
    }

    func run(
        step: ActionPlanStep, tools: [ActionToolSpec], maxSteps: Int,
        execute: @escaping @Sendable (ActionToolSpec, String) async throws -> String,
        onEvent: @escaping @Sendable (ActionPlanEvent) -> Void
    ) async throws -> String {
        dispatchPrecondition(condition: .onQueue(.main))
        let task = step.task
        let intent = HeuristicIntentExtractor.intent(for: task)
        guard [.click, .typeText, .other].contains(intent.action) else {
            return try await fallback.run(step: step, tools: tools, maxSteps: maxSteps, execute: execute, onEvent: onEvent)
        }
        guard let driver = NativeGroundingTools(tools) else {
            if NativeActionStep.literal(task) != nil {
                throw ActionChoiceError.invalid("enable one Cua Driver server with observation-local element_token support")
            }
            let available = tools.filter { !NativeGroundingTools.isNativeMutation($0) }
            return try await fallback.run(step: step, tools: available, maxSteps: maxSteps, execute: execute, onEvent: onEvent)
        }
        let executor = NativeGroundedExecutor(driver: driver, chooser: chooser, execute: execute)
        if let step = NativeActionStep.literal(task) {
            onEvent(.planning)
            return try await executor.perform(step)
        }
        let helpers = driver.helpers
        let plannedTools = helpers + tools.filter {
            $0.serverID != driver.click.serverID || !["click", "set_value", "type_text"].contains($0.toolName)
        }
        let result = try await fallback.run(step: step, tools: plannedTools, maxSteps: maxSteps, execute: { spec, arguments in
            if let helper = helpers.first(where: { $0.id == spec.id }) {
                let operation: NativeActionStep.Operation = helper.toolName == "superkeet_native_click" ? .click : .setText
                return try await executor.perform(NativeActionStep.decode(arguments, operation: operation))
            }
            return try await executor.performExternal(spec, arguments: arguments)
        }, onEvent: onEvent)
        if let message = await executor.stoppedMessage {
            onEvent(.message(message))
            return message
        }
        return result
    }
}

struct NativeGroundingTools: Sendable {
    let windows: ActionToolSpec
    let observe: ActionToolSpec
    let click: ActionToolSpec
    let setText: ActionToolSpec

    static func isNativeMutation(_ spec: ActionToolSpec) -> Bool {
        spec.serverName.lowercased().replacingOccurrences(of: "_", with: "-") == "cua-driver"
            && ["click", "set_value", "type_text"].contains(spec.toolName)
    }

    init?(_ tools: [ActionToolSpec]) {
        let servers = Set(tools.filter { $0.serverName.lowercased().replacingOccurrences(of: "_", with: "-") == "cua-driver" }
            .map(\.serverID))
        guard servers.count == 1, let serverID = servers.first else { return nil }
        let available = tools.filter { $0.serverID == serverID }
        func tool(_ name: String, arguments: Set<String>, observation: Bool = false) -> ActionToolSpec? {
            guard let spec = available.first(where: { $0.toolName == name }),
                  let schema = try? NativeGroundingJSON.object(spec.inputSchemaJSON),
                  let properties = schema["properties"] as? [String: Any],
                  arguments.isSubset(of: Set(properties.keys)),
                  Set(schema["required"] as? [String] ?? []).isSubset(of: arguments),
                  !observation || spec.risk == .readOnly else { return nil }
            var result = spec
            result.nativeObservation = observation
            return result
        }
        guard let windows = tool("list_windows", arguments: ["on_screen_only"], observation: true),
              let observe = tool("get_window_state", arguments: ["pid", "window_id", "include_screenshot", "session"], observation: true),
              let click = tool("click", arguments: ["pid", "window_id", "element_token", "session"]),
              let setText = tool("set_value", arguments: ["pid", "window_id", "element_token", "value", "session"]) else { return nil }
        self.windows = windows
        self.observe = observe
        self.click = Self.mutating(click)
        self.setText = Self.mutating(setText)
    }

    var helpers: [ActionToolSpec] {
        [helper("superkeet_native_click", description: "Click one named native control in an app using fresh accessibility grounding.", text: false),
         helper("superkeet_native_set_text", description: "Replace one named native text field with exact supplied text using accessibility grounding.", text: true)]
    }

    private func helper(_ name: String, description: String, text: Bool) -> ActionToolSpec {
        let fields = text ? ["app", "target", "text"] : ["app", "target"]
        let properties = Dictionary(uniqueKeysWithValues: fields.map { ($0, ["type": "string"]) })
        let schema = (try? NativeGroundingJSON.encode(["type": "object", "properties": properties, "required": fields])) ?? "{}"
        return ActionToolSpec(descriptor: MCPToolDescriptor(
            serverID: click.serverID, serverName: click.serverName, name: name, title: nil,
            description: description, risk: .mutating, inputSchemaJSON: schema
        ))
    }

    private static func mutating(_ spec: ActionToolSpec) -> ActionToolSpec {
        ActionToolSpec(descriptor: MCPToolDescriptor(
            serverID: spec.serverID, serverName: spec.serverName, name: spec.toolName, title: spec.displayName,
            description: spec.description, risk: spec.risk == .destructive ? .destructive : .mutating,
            inputSchemaJSON: spec.inputSchemaJSON
        ))
    }
}

private actor NativeGroundedExecutor {
    private let driver: NativeGroundingTools
    private let chooser: any ActionChoosing
    private let execute: @Sendable (ActionToolSpec, String) async throws -> String
    private let session = "superkeet-\(UUID().uuidString.lowercased())"
    private var busy = false
    private var halted = false
    private var attempted = Set<String>()
    private var attemptedControls = Set<String>()
    private(set) var stoppedMessage: String?

    init(driver: NativeGroundingTools, chooser: any ActionChoosing,
         execute: @escaping @Sendable (ActionToolSpec, String) async throws -> String) {
        self.driver = driver
        self.chooser = chooser
        self.execute = execute
    }

    func checkCanContinue() throws {
        try Task.checkCancellation()
        guard !halted, !busy else { throw ActionChoiceError.invalid("the grounded step stopped; issue a new command") }
    }

    func performExternal(_ spec: ActionToolSpec, arguments: String) async throws -> String {
        try checkCanContinue()
        busy = true
        defer { busy = false }
        return try await execute(spec, arguments)
    }

    func perform(_ step: NativeActionStep) async throws -> String {
        try checkCanContinue()
        try step.validate()
        guard !attempted.contains(step.key) else { throw ActionChoiceError.invalid("this action was already attempted") }
        busy = true
        defer { busy = false }
        do {
            try await chooser.prepare()
            let windows = try await execute(driver.windows, #"{"on_screen_only":true}"#)
            let window = try NativeGroundingWindow.resolve(windows, app: step.app)
            var history: [ChoiceRequest.History] = []
            var previousCapture: String?
            for _ in 0..<2 {
                try Task.checkCancellation()
                let snapshot = try await observe(window)
                guard previousCapture != snapshot.captureID else { throw ActionChoiceError.invalid("Driver reused a stale snapshot") }
                previousCapture = snapshot.captureID
                let table = try snapshot.candidates(step: step, tool: step.operation == .click ? driver.click : driver.setText, session: session)
                let request = ChoiceRequest(goal: step.goal, captureID: snapshot.captureID, regions: [], history: history,
                                            candidates: table.map { .init(id: $0.id, description: $0.description) })
                _ = try request.encoded()
                let began = ContinuousClock.now
                let response = try await chooser.choose(request)
                let duration = began.duration(to: .now).components
                let milliseconds = Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
                let candidate = try response.validatedCandidate(in: table, currentCaptureID: snapshot.captureID)
                if candidate.id == "abstain" {
                    return stop("No matching native control was selected. This step made no changes.")
                }
                if candidate.id == "reobserve" {
                    history.append(.init(selectedID: candidate.id, outcome: "reobserved"))
                    continue
                }
                let selected = try snapshot.selectedElement(candidate)
                guard let score = response.probabilities[candidate.id], abs(score - response.confidence) < 0.001,
                      response.probabilities.filter({ $0.key != candidate.id }).values.allSatisfy({ $0 < score }) else {
                    throw ActionChoiceError.invalid("the grounder supplied inconsistent or tied scores")
                }
                guard let tool = candidate.tool else { throw ActionChoiceError.invalid("selected action has no tool") }
                var spec = tool
                spec.approvalSummary = "\(candidate.description) in \(step.app)"
                spec.groundingDecision = .init(selectedID: candidate.id, confidence: response.confidence, decisionMilliseconds: milliseconds)
                spec.nativePreflight = .init(window: window, session: session, control: selected,
                                             observationSchemaJSON: driver.observe.inputSchemaJSON, windowTitle: snapshot.windowTitle)
                // Mark before dispatch: errors/timeouts may still have caused side effects.
                let controlKey = [String(window.pid), String(window.windowID), step.operation.rawValue,
                                  selected.role, selected.label, step.text ?? ""] + selected.context
                guard attemptedControls.insert(controlKey.map(NativeGroundingJSON.quote).joined()).inserted else {
                    throw ActionChoiceError.invalid("this control's action was already attempted")
                }
                attempted.insert(step.key)
                let output = try await execute(spec, candidate.argumentsJSON)
                _ = try NativeGroundingJSON.object(output)
                return try await verify(step, selected: selected, window: window)
            }
            return stop("The grounder requested another observation twice. This step made no changes.")
        } catch {
            halted = true
            throw error
        }
    }

    private func observe(_ window: NativeGroundingWindow) async throws -> NativeGroundingSnapshot {
        let arguments = try NativeGroundingJSON.encode(["pid": window.pid, "window_id": window.windowID,
                                                       "include_screenshot": false, "session": session])
        let json = try await execute(driver.observe, arguments)
        return try NativeGroundingSnapshot(json: json, window: window)
    }

    private func verify(_ step: NativeActionStep, selected: NativeGroundingSnapshot.Element,
                        window: NativeGroundingWindow) async throws -> String {
        do {
            let fresh = try await observe(window)
            if step.operation == .setText, let text = step.text,
               !fresh.elements.contains(where: { $0.token == selected.token }), fresh.verifies(text: text, control: selected) {
                return "The text field's new value was verified in a fresh accessibility observation."
            }
        } catch {
            try Task.checkCancellation()
            // An unavailable postcondition must never trigger another mutation or a new plan.
        }
        return stop("The native action was sent once, but its effect could not be independently verified. Stopped without retrying.")
    }

    private func stop(_ message: String) -> String {
        halted = true
        stoppedMessage = message
        return message
    }
}
