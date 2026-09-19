import XCTest
@testable import Superkeet

@MainActor
final class NativeActionExecutorTests: XCTestCase {
    final class Workspace: NativeWorkspaceOpening {
        var openedApps: [URL] = []
        var openedURLs: [(URL, URL?)] = []
        var failure: Error?
        var windowReady = true
        func applicationURL(bundleIdentifier: String) -> URL? { nil }
        func openApplication(at url: URL) async throws -> NativeLaunchedApp {
            if let failure { throw failure }
            openedApps.append(url)
            let name = url.deletingPathExtension().lastPathComponent
            return NativeLaunchedApp(name: name, bundleIdentifier: "com.fixture.\(name.lowercased())",
                                     processIdentifier: 4_242, windowReady: windowReady)
        }
        func openURL(_ url: URL, in application: URL?) async throws {
            if let failure { throw failure }
            openedURLs.append((url, application))
        }
    }

    final class Shortcuts: NativeShortcutPressing {
        private(set) var pressed: [(KeyboardShortcut, URL)] = []
        var failure: Error?
        func press(_ shortcut: KeyboardShortcut, inApplicationAt url: URL) async throws -> Int32 {
            if let failure { throw failure }
            pressed.append((shortcut, url))
            return 555
        }
    }

    private func executor(_ workspace: Workspace, shortcuts: Shortcuts = Shortcuts()) -> NativeActionExecutor {
        let apps = ["Helium", "Discord", "Notes"].map { URL(fileURLWithPath: "/fixture/Applications/\($0).app") }
        return NativeActionExecutor(
            resolver: AppResolver(directories: [URL(fileURLWithPath: "/fixture/Applications")], applicationsInDirectory: { _ in apps }),
            workspace: workspace,
            shortcuts: shortcuts
        )
    }

    func testPressesShortcutInResolvedApp() async throws {
        let shortcuts = Shortcuts()
        let chord = try XCTUnwrap(KeyboardShortcut(keys: ["cmd", "n"]))
        let output = try await executor(Workspace(), shortcuts: shortcuts).execute(.pressShortcut(app: "the notes app", shortcut: chord))
        XCTAssertEqual(shortcuts.pressed.count, 1)
        XCTAssertEqual(shortcuts.pressed.first?.0, chord)
        XCTAssertEqual(shortcuts.pressed.first?.1.lastPathComponent, "Notes.app")
        XCTAssertEqual(output, "Pressed ⌘N in Notes (pid 555).")
    }

    func testShortcutForUnknownAppFailsBeforePressing() async throws {
        let shortcuts = Shortcuts()
        let chord = try XCTUnwrap(KeyboardShortcut(keys: ["cmd", "s"]))
        do {
            _ = try await executor(Workspace(), shortcuts: shortcuts).execute(.pressShortcut(app: "Missing", shortcut: chord))
            XCTFail("Expected resolution miss")
        } catch { XCTAssertEqual(error as? NativeOpenActionError, .appNotFound("Missing")) }
        XCTAssertTrue(shortcuts.pressed.isEmpty)
    }

    func testShortcutDeliveryErrorsKeepTheirIdentity() async throws {
        let chord = try XCTUnwrap(KeyboardShortcut(keys: ["cmd", "q"]))
        for failure in [NativeOpenActionError.appNotRunning("Notes"), .accessibilityRequired] {
            let shortcuts = Shortcuts()
            shortcuts.failure = failure
            do {
                _ = try await executor(Workspace(), shortcuts: shortcuts).execute(.pressShortcut(app: "Notes", shortcut: chord))
                XCTFail("Expected \(failure)")
            } catch { XCTAssertEqual(error as? NativeOpenActionError, failure) }
        }
    }

    func testSystemPresserActivatesWaitsForFrontmostAndPosts() async throws {
        let url = URL(fileURLWithPath: "/fixture/Applications/Notes.app")
        let chord = try XCTUnwrap(KeyboardShortcut(keys: ["cmd", "n"]))
        let posted = OSAllocatedUnfairLockBox<[KeyboardShortcut]>([])
        let frontmost = OSAllocatedUnfairLockBox<pid_t?>(1)
        let finder = NSRunningApplication.current
        var environment = SystemShortcutPresser.Environment()
        environment.accessibilityTrusted = { true }
        environment.runningApplication = { _ in finder }
        environment.frontmostProcessIdentifier = {
            let current = frontmost.value
            frontmost.mutate { $0 = finder.processIdentifier }
            return current
        }
        environment.post = { chord in
            posted.mutate { $0.append(chord) }
            return true
        }
        let presser = SystemShortcutPresser(environment: environment)
        let pid = try await presser.press(chord, inApplicationAt: url)
        XCTAssertEqual(pid, finder.processIdentifier)
        XCTAssertEqual(posted.value, [chord])
    }

    func testSystemPresserRefusesWithoutAccessibilityRunningAppOrFocus() async throws {
        let url = URL(fileURLWithPath: "/fixture/Applications/Notes.app")
        let chord = try XCTUnwrap(KeyboardShortcut(keys: ["cmd", "n"]))
        let posted = OSAllocatedUnfairLockBox(0)
        let ownApp = NSRunningApplication.current

        var denied = SystemShortcutPresser.Environment()
        denied.accessibilityTrusted = { false }
        denied.post = { _ in posted.mutate { $0 += 1 }; return true }
        do { _ = try await SystemShortcutPresser(environment: denied).press(chord, inApplicationAt: url); XCTFail("Expected an accessibility error") } catch {
            XCTAssertEqual(error as? NativeOpenActionError, .accessibilityRequired)
        }

        var notRunning = SystemShortcutPresser.Environment()
        notRunning.accessibilityTrusted = { true }
        notRunning.runningApplication = { _ in nil }
        notRunning.post = { _ in posted.mutate { $0 += 1 }; return true }
        do { _ = try await SystemShortcutPresser(environment: notRunning).press(chord, inApplicationAt: url); XCTFail("Expected a not-running error") } catch {
            XCTAssertEqual(error as? NativeOpenActionError, .appNotRunning("Notes"))
        }

        var neverFrontmost = SystemShortcutPresser.Environment()
        neverFrontmost.accessibilityTrusted = { true }
        neverFrontmost.runningApplication = { _ in ownApp }
        neverFrontmost.frontmostProcessIdentifier = { 1 }
        neverFrontmost.activationTimeout = .milliseconds(80)
        neverFrontmost.post = { _ in posted.mutate { $0 += 1 }; return true }
        do { _ = try await SystemShortcutPresser(environment: neverFrontmost).press(chord, inApplicationAt: url); XCTFail("Expected a focus error") } catch {
            XCTAssertTrue((error as? NativeOpenActionError)?.localizedDescription.contains("did not come to the front") == true)
        }
        XCTAssertEqual(posted.value, 0, "No key event is ever posted unless the target app is frontmost.")
    }

    func testOpensResolvedAppUsingWorkspace() async throws {
        let workspace = Workspace()
        let output = try await executor(workspace).execute(.openApp(name: "discord APP."))
        XCTAssertEqual(workspace.openedApps.map(\.lastPathComponent), ["Discord.app"])
        XCTAssertEqual(output, "Opened Discord (pid 4242, com.fixture.discord). Its window is on screen.")
        XCTAssertTrue(workspace.openedURLs.isEmpty)
    }

    func testReportsWhenNoWindowAppearedWithoutFailing() async throws {
        let workspace = Workspace()
        workspace.windowReady = false
        let output = try await executor(workspace).execute(.openApp(name: "Discord"))
        XCTAssertEqual(output, "Opened Discord (pid 4242, com.fixture.discord). No window has appeared yet.")
    }

    func testLaunchSummaryOmitsMissingBundleIdentifier() {
        let launched = NativeLaunchedApp(name: "Tool", bundleIdentifier: nil, processIdentifier: 7, windowReady: true)
        XCTAssertEqual(launched.summary, "Opened Tool (pid 7). Its window is on screen.")
        let blank = NativeLaunchedApp(name: "Tool", bundleIdentifier: "", processIdentifier: 7, windowReady: false)
        XCTAssertEqual(blank.summary, "Opened Tool (pid 7). No window has appeared yet.")
    }

    func testWindowProbeIsFalseForWindowlessProcess() {
        XCTAssertFalse(SystemNativeWorkspace.hasOrdinaryWindow(processIdentifier: 1))
    }

    func testLaunchWaiterReturnsOnceReady() async throws {
        var polls = 0
        let waiter = NativeLaunchWaiter(timeout: .seconds(2), pollInterval: .milliseconds(5))
        let ready = try await waiter.wait {
            polls += 1
            return polls >= 3
        }
        XCTAssertTrue(ready)
        XCTAssertEqual(polls, 3)
    }

    func testLaunchWaiterGivesUpAtTimeoutWithoutThrowing() async throws {
        let waiter = NativeLaunchWaiter(timeout: .milliseconds(60), pollInterval: .milliseconds(5))
        let clock = ContinuousClock()
        let started = clock.now
        let ready = try await waiter.wait { false }
        XCTAssertFalse(ready)
        XCTAssertGreaterThanOrEqual(clock.now - started, .milliseconds(60))
    }

    func testLaunchWaiterPropagatesCancellation() async {
        let waiter = NativeLaunchWaiter(timeout: .seconds(10), pollInterval: .milliseconds(5))
        let task = Task { @MainActor in try await waiter.wait { false } }
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testNamedBrowserAndDefaultHandlerAreSeparateRoutes() async throws {
        let workspace = Workspace()
        let executor = executor(workspace)
        let url = try XCTUnwrap(URL(string: "https://youtube.com"))
        _ = try await executor.execute(.openURL(url: url, browser: "Helium browser"))
        _ = try await executor.execute(.openURL(url: url, browser: nil))
        XCTAssertEqual(workspace.openedURLs.map { $0.0 }, [url, url])
        XCTAssertEqual(workspace.openedURLs[0].1?.lastPathComponent, "Helium.app")
        XCTAssertNil(workspace.openedURLs[1].1)
        XCTAssertTrue(workspace.openedApps.isEmpty, "Opening a URL should not separately launch and retry the browser.")
    }

    func testMissingAppOrNamedBrowserFailsBeforeAnyOpen() async throws {
        let workspace = Workspace()
        let executor = executor(workspace)
        let actions: [NativeOpenAction] = [.openApp(name: "Missing"), .openURL(url: try XCTUnwrap(URL(string: "https://example.com")), browser: "Missing")]
        for action in actions {
            do {
                _ = try await executor.execute(action)
                XCTFail("Expected resolution miss")
            } catch { XCTAssertEqual(error as? NativeOpenActionError, .appNotFound("Missing")) }
        }
        XCTAssertTrue(workspace.openedApps.isEmpty)
        XCTAssertTrue(workspace.openedURLs.isEmpty)
    }

    func testLaunchErrorIsNotReportedAsResolutionMiss() async {
        let workspace = Workspace()
        workspace.failure = NSError(domain: "WorkspaceFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Launch refused"])
        do {
            _ = try await executor(workspace).execute(.openApp(name: "Discord"))
            XCTFail("Expected launch failure")
        } catch { XCTAssertEqual(error as? NativeOpenActionError, .openFailed("Launch refused")) }
    }

    func testCancellationBeforeDispatchDoesNotOpen() async {
        let workspace = Workspace()
        let executor = executor(workspace)
        let task = Task { try await executor.execute(.openApp(name: "Discord")) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(workspace.openedApps.isEmpty)
    }

    func testWorkspaceUserCancellationKeepsItsCancellationIdentity() async {
        let workspace = Workspace()
        workspace.failure = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        do {
            _ = try await executor(workspace).execute(.openApp(name: "Discord"))
            XCTFail("Expected user cancellation")
        } catch { XCTAssertTrue(ActionErrorHandling.isCancellation(error)) }
        XCTAssertTrue(workspace.openedApps.isEmpty)
    }
}
