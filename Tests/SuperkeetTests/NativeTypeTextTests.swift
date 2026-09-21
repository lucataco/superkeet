import XCTest
@testable import Superkeet

@MainActor
final class NativeTypeTextTests: XCTestCase {
    final class Typer: NativeTextTyping {
        private(set) var typed: [(text: String, app: URL)] = []
        var failure: Error?
        func type(_ text: String, inApplicationAt url: URL) async throws -> Int32 {
            if let failure { throw failure }
            typed.append((text, url))
            return 77
        }
    }

    func testRecipesExtractTextAndTarget() {
        XCTAssertEqual(NativeTypeRecipe.recipe(for: "type hello"), .init(text: "hello", target: .current))
        XCTAssertEqual(NativeTypeRecipe.recipe(for: "let's make the title say hello."), .init(text: "hello", target: .current))
        XCTAssertEqual(NativeTypeRecipe.recipe(for: "Make it say Hello, world!"), .init(text: "Hello, world!", target: .current))
        XCTAssertEqual(NativeTypeRecipe.recipe(for: "set the heading to Groceries"), .init(text: "Groceries", target: .current))
        XCTAssertEqual(NativeTypeRecipe.recipe(for: "name it Weekly review"), .init(text: "Weekly review", target: .current))
        XCTAssertEqual(NativeTypeRecipe.recipe(for: "type okay"), .init(text: "okay", target: .current), "Typed words are never filler.")
        XCTAssertEqual(NativeTypeRecipe.recipe(for: "write down “call mom tomorrow”"), .init(text: "call mom tomorrow", target: .current))

        let named = NativeTypeRecipe.recipe(for: "write \"shopping list\" in Notes")
        XCTAssertEqual(named?.text, "shopping list")
        XCTAssertEqual(named?.target, .named("Notes"))
        XCTAssertEqual(NativeTypeRecipe.recipe(for: "enter my name in the Notes app")?.target, .named("Notes"))

        let field = NativeTypeRecipe.recipe(for: "type milk, eggs and bread into Body")
        XCTAssertEqual(field?.text, "milk, eggs and bread")
        XCTAssertEqual(field?.target, .named("Body"))
        XCTAssertEqual(field?.fullText, "milk, eggs and bread into Body", "If Body is not an app, the whole phrase is the text.")
    }

    func testRecipesDeferToShortcutsAndIgnoreNonTyping() {
        XCTAssertNil(NativeTypeRecipe.recipe(for: "write a new note"), "⌘N, not typed text.")
        XCTAssertNil(NativeTypeRecipe.recipe(for: "open Notes"))
        XCTAssertNil(NativeTypeRecipe.recipe(for: "make the window bigger"))
        XCTAssertNil(NativeTypeRecipe.recipe(for: "type"))
        XCTAssertNil(NativeTypeRecipe.recipe(for: "click Save"))
        XCTAssertEqual(NativeTypeRecipe.patterns.count, 4, "Every pattern compiles.")
    }

    func testTypeTextActionEncodesDecodesAndIsExempt() throws {
        let action = NativeOpenAction.typeText(app: "Notes", text: "hello")
        XCTAssertEqual(action.toolName, "type_text")
        XCTAssertTrue(action.isApprovalExempt)
        XCTAssertTrue(action.spec.approvalExempt)
        XCTAssertEqual(action.spec.risk, .mutating)
        let json = try action.argumentsJSON()
        XCTAssertEqual(try NativeOpenAction.decode(toolName: "type_text", argumentsJSON: json), action)
        XCTAssertThrowsError(try NativeOpenAction.decode(toolName: "type_text", argumentsJSON: #"{"app":"Notes","text":"  "}"#))
        XCTAssertThrowsError(try NativeOpenAction.decode(toolName: "type_text", argumentsJSON: #"{"text":"hello"}"#))
        XCTAssertEqual(ActionIntentFormatter.summary(toolName: "type_text", argumentsJSON: json), "Type “hello” in Notes")
        XCTAssertEqual(NativeOpenAction.tools.map(\.toolName), ["open_app", "open_url", "press_shortcut", "type_text"])
        XCTAssertTrue(NativeOpenAction.plansWithoutMCP("open Notes and make the title say hello"))
        XCTAssertTrue(NativeOpenAction.plansWithoutMCP("type hello"))
    }

    func testExecutorTypesInTheResolvedApp() async throws {
        let typer = Typer()
        let apps = ["Notes"].map { URL(fileURLWithPath: "/fixture/Applications/\($0).app") }
        let executor = NativeActionExecutor(
            resolver: AppResolver(directories: [URL(fileURLWithPath: "/fixture/Applications")], applicationsInDirectory: { _ in apps }),
            workspace: NativeActionExecutorTests.Workspace(),
            shortcuts: NativeActionExecutorTests.Shortcuts(),
            typer: typer
        )
        let output = try await executor.execute(.typeText(app: "the notes app", text: "hello"))
        XCTAssertEqual(typer.typed.first?.text, "hello")
        XCTAssertEqual(typer.typed.first?.app.lastPathComponent, "Notes.app")
        XCTAssertEqual(output, "Typed “hello” in Notes (pid 77).")

        do {
            _ = try await executor.execute(.typeText(app: "Missing", text: "hello"))
            XCTFail("Expected resolution miss")
        } catch { XCTAssertEqual(error as? NativeOpenActionError, .appNotFound("Missing")) }
        XCTAssertEqual(typer.typed.count, 1)
    }

    func testSystemTyperChunksTextAndPressesReturnBetweenLines() async throws {
        let url = URL(fileURLWithPath: "/fixture/Applications/Notes.app")
        let posted = OSAllocatedUnfairLockBox<[String]>([])
        let returns = OSAllocatedUnfairLockBox(0)
        let ownApp = NSRunningApplication.current
        var environment = SystemTextTyper.Environment()
        environment.accessibilityTrusted = { true }
        environment.runningApplication = { _ in ownApp }
        environment.frontmostProcessIdentifier = { ownApp.processIdentifier }
        environment.postText = { chunk in posted.mutate { $0.append(chunk) }; return true }
        environment.postReturn = { returns.mutate { $0 += 1 }; return true }
        environment.chunkDelay = .zero

        let pid = try await SystemTextTyper(environment: environment).type("hello\nthe quick brown fox jumps over the lazy dog", inApplicationAt: url)
        XCTAssertEqual(pid, ownApp.processIdentifier)
        XCTAssertEqual(returns.value, 1)
        XCTAssertEqual(posted.value.joined(), "hellothe quick brown fox jumps over the lazy dog")
        XCTAssertTrue(posted.value.allSatisfy { $0.utf16.count <= SystemTextTyper.chunkLength })
        XCTAssertEqual(SystemTextTyper.chunks(of: ""), [])
        XCTAssertEqual(SystemTextTyper.chunks(of: "héllo 👋 wörld").joined(), "héllo 👋 wörld")
    }

    func testSystemTyperRefusesWithoutAccessibilityOrRunningApp() async {
        let url = URL(fileURLWithPath: "/fixture/Applications/Notes.app")
        var denied = SystemTextTyper.Environment()
        denied.accessibilityTrusted = { false }
        do { _ = try await SystemTextTyper(environment: denied).type("x", inApplicationAt: url); XCTFail("Expected accessibility error") } catch {
            XCTAssertEqual(error as? NativeOpenActionError, .accessibilityRequired)
        }
        var notRunning = SystemTextTyper.Environment()
        notRunning.accessibilityTrusted = { true }
        notRunning.runningApplication = { _ in nil }
        do { _ = try await SystemTextTyper(environment: notRunning).type("x", inApplicationAt: url); XCTFail("Expected not-running error") } catch {
            XCTAssertEqual(error as? NativeOpenActionError, .appNotRunning("Notes"))
        }
    }

    func testControllerTypesIntoTheAppItJustOpened() async throws {
        let notes = URL(fileURLWithPath: "/fixture/Applications/Notes.app")
        let router = AgentSessionControllerTests.FakeRouter(specs: [])
        router.preparationFailure = ActionExecutionError.noMCPServersEnabled
        router.outputs["open_app"] = NativeLaunchedApp(name: "Notes", bundleIdentifier: "com.apple.Notes", processIdentifier: 91, windowReady: true).summary
        router.outputs["press_shortcut"] = "Pressed ⌘N in Notes (pid 91)."
        router.outputs["type_text"] = "Typed “hello” in Notes (pid 91)."
        var plannerCreated = false
        let controller = AgentSessionController(
            settings: .shared, router: router, plannerFactory: { plannerCreated = true; return nil },
            resolveApp: { AppResolver.normalizedName($0).contains("notes") ? notes : nil }, isAppRunning: { $0 == notes },
            frontmostApp: { nil }
        )
        controller.handleCommand("Can you open up the Notes app for me? And once you're there, create a new note. And inside this new note, let's make the title say hello.")
        let deadline = Date().addingTimeInterval(5)
        while controller.phase.isActive && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }

        XCTAssertEqual(router.executed, ["open_app", "press_shortcut", "type_text"])
        XCTAssertEqual(try NativeOpenAction.decode(toolName: "type_text", argumentsJSON: XCTUnwrap(router.arguments.last)),
                       .typeText(app: "Notes", text: "hello"))
        XCTAssertFalse(plannerCreated, "Open, ⌘N, and typing are all native; no model is needed.")
        XCTAssertTrue(controller.activityLog.contains("Typing “hello” in Notes"))
        if case .finished = controller.phase {} else { XCTFail("Expected success, got \(controller.phase)") }
    }

    func testTypingWithNothingOpenGoesToTheFrontmostApp() async throws {
        let notes = URL(fileURLWithPath: "/fixture/Applications/Notes.app")
        let router = AgentSessionControllerTests.FakeRouter(specs: [])
        router.preparationFailure = ActionExecutionError.noMCPServersEnabled
        router.outputs["type_text"] = "Typed “restaurants in Paris” in Notes (pid 91)."
        let controller = AgentSessionController(
            settings: .shared, router: router, plannerFactory: { nil },
            resolveApp: { AppResolver.normalizedName($0).contains("notes") ? notes : nil }, isAppRunning: { $0 == notes },
            frontmostApp: { "Notes" }
        )
        controller.handleCommand("type restaurants in Paris")
        let deadline = Date().addingTimeInterval(5)
        while controller.phase.isActive && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }

        XCTAssertEqual(router.executed, ["type_text"])
        XCTAssertEqual(try NativeOpenAction.decode(toolName: "type_text", argumentsJSON: XCTUnwrap(router.arguments.last)),
                       .typeText(app: "Notes", text: "restaurants in Paris"), "Paris is not an app, so it stays part of the text.")
    }
}
