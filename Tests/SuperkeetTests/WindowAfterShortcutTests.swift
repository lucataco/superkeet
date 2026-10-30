import CoreGraphics
import XCTest
@testable import Superkeet

/// Models the on-screen windows of one app as the final command sees them. After ⌘N the Open
/// panel stays up for a moment, then disappears, and only later does the new document appear.
/// Each probe of the window list advances this script by one step.
private final class FakeAppWindows: @unchecked Sendable {
    struct Typed: Equatable {
        let text: String
        let windows: Set<CGWindowID>
    }

    private struct State {
        var pressed = false
        var probes = 0
        var typed: [Typed] = []
    }

    static let openPanel: CGWindowID = 7
    static let newDocument: CGWindowID = 9

    private let state = OSAllocatedUnfairLockBox(State())
    private let afterPress: [Set<CGWindowID>]

    init(afterPress: [Set<CGWindowID>]) {
        self.afterPress = afterPress
    }

    static func documentAppearsLate() -> FakeAppWindows {
        FakeAppWindows(afterPress: [[openPanel], [openPanel], [], [], [newDocument]])
    }

    static func nothingEverAppears() -> FakeAppWindows {
        FakeAppWindows(afterPress: [[openPanel]])
    }

    private func visible(_ state: State) -> Set<CGWindowID> {
        guard state.pressed else { return [Self.openPanel] }
        return afterPress[min(state.probes, afterPress.count - 1)]
    }

    func press() { state.mutate { $0.pressed = true } }

    func probe() -> Set<CGWindowID> {
        var seen: Set<CGWindowID> = []
        state.mutate {
            seen = visible($0)
            if $0.pressed { $0.probes += 1 }
        }
        return seen
    }

    func type(_ text: String) {
        state.mutate { $0.typed.append(Typed(text: text, windows: visible($0))) }
    }

    var typed: [Typed] { state.value.typed }
}

@MainActor
final class WindowAfterShortcutTests: XCTestCase {
    private let textEdit = URL(fileURLWithPath: "/fixture/Applications/TextEdit.app")

    private func presser(_ windows: FakeAppWindows, windowTimeout: Duration = .seconds(5)) -> SystemShortcutPresser {
        let app = NSRunningApplication.current
        var environment = SystemShortcutPresser.Environment()
        environment.accessibilityTrusted = { true }
        environment.runningApplication = { _ in app }
        environment.frontmostProcessIdentifier = { app.processIdentifier }
        environment.post = { _ in windows.press(); return true }
        environment.windowIdentifiers = { _ in windows.probe() }
        environment.windowTimeout = windowTimeout
        environment.windowPollInterval = .milliseconds(1)
        return SystemShortcutPresser(environment: environment)
    }

    private func typer(_ windows: FakeAppWindows) -> SystemTextTyper {
        let app = NSRunningApplication.current
        var environment = SystemTextTyper.Environment()
        environment.accessibilityTrusted = { true }
        environment.runningApplication = { _ in app }
        environment.frontmostProcessIdentifier = { app.processIdentifier }
        environment.postText = { windows.type($0); return true }
        environment.chunkDelay = .zero
        return SystemTextTyper(environment: environment)
    }

    private func executor(_ windows: FakeAppWindows, windowTimeout: Duration = .seconds(5)) -> NativeActionExecutor {
        NativeActionExecutor(
            resolver: AppResolver(directories: [URL(fileURLWithPath: "/fixture/Applications")], applicationsInDirectory: { [textEdit] _ in [textEdit] }),
            workspace: NativeActionExecutorTests.Workspace(),
            shortcuts: presser(windows, windowTimeout: windowTimeout),
            typer: typer(windows)
        )
    }

    private final class ExecutorRouter: ActionRouting {
        let executor: NativeActionExecutor
        init(_ executor: NativeActionExecutor) { self.executor = executor }
        func prepareTools() async throws -> [ActionToolSpec] { [] }
        func execute(spec: ActionToolSpec, argumentsJSON: String) async throws -> String {
            try await executor.execute(NativeOpenAction.decode(toolName: spec.toolName, argumentsJSON: argumentsJSON))
        }
    }

    func testFinalCommandTypesOnlyOnceTheNewDocumentWindowExists() async throws {
        let windows = FakeAppWindows.documentAppearsLate()
        let router = ExecutorRouter(executor(windows))
        let app = textEdit
        let controller = AgentSessionController(
            router: router, plannerFactory: { nil },
            resolveApp: { AppResolver.normalizedName($0).contains("textedit") ? app : nil }, isAppRunning: { $0 == app },
            frontmostApp: { nil }
        )
        controller.handleCommand("Open TextEdit. Create a new document. Make the title say hello.")
        let deadline = Date().addingTimeInterval(10)
        while controller.phase.isActive && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }

        guard case .finished(let summary) = controller.phase else { return XCTFail("The command ended as \(controller.phase).") }
        XCTAssertTrue(summary.contains("Typed “hello” in TextEdit"), "The command reports the text as typed.")
        XCTAssertEqual(windows.typed.map(\.text).joined(), "hello")
        XCTAssertTrue(
            windows.typed.allSatisfy { $0.windows.contains(FakeAppWindows.newDocument) },
            "The text was typed while TextEdit showed \(windows.typed.map(\.windows)), before the document window existed."
        )
    }

    func testPressGivesUpWhenNoWindowAppearsAndStillSucceeds() async throws {
        let windows = FakeAppWindows.nothingEverAppears()
        let timeout = Duration.milliseconds(80)
        let executor = executor(windows, windowTimeout: timeout)
        let clock = ContinuousClock()
        let started = clock.now
        let output = try await executor.execute(.pressShortcut(app: "TextEdit", shortcut: XCTUnwrap(KeyboardShortcut(keys: ["cmd", "n"]))))
        XCTAssertGreaterThanOrEqual(started.duration(to: clock.now), timeout, "⌘N waits the whole bounded time for a window before it moves on.")
        XCTAssertTrue(output.hasPrefix("Pressed ⌘N in TextEdit"), "A missing window is not a failure, the shortcut was still delivered.")

        _ = try await executor.execute(.typeText(app: "TextEdit", text: "hello"))
        XCTAssertEqual(windows.typed.map(\.text).joined(), "hello", "The next step still runs after the wait gives up.")
    }

    func testShortcutsThatMakeNoWindowDoNotWait() async throws {
        let windows = FakeAppWindows.nothingEverAppears()
        let executor = executor(windows, windowTimeout: .seconds(30))
        let clock = ContinuousClock()
        let started = clock.now
        for keys in [["cmd", "s"], ["cmd", "t"], ["cmd", "z"]] {
            _ = try await executor.execute(.pressShortcut(app: "TextEdit", shortcut: XCTUnwrap(KeyboardShortcut(keys: keys))))
        }
        XCTAssertLessThan(started.duration(to: clock.now), .seconds(5))
    }
}
