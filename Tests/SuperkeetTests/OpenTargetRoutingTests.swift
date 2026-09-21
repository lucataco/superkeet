import XCTest
@testable import Superkeet

private let resolveTelegramFixture: @MainActor @Sendable (String) -> URL? = { name in
    guard AppResolver.normalizedName(name) == "telegram" else { return nil }
    return URL(fileURLWithPath: "/fixture/Telegram.app")
}

@MainActor
final class OpenTargetRoutingTests: XCTestCase {
    private let telegram = NativeLaunchedApp(name: "Telegram", bundleIdentifier: "org.telegram.desktop", processIdentifier: 91, windowReady: true)

    private func waitUntilFinished(_ controller: AgentSessionController) async {
        let deadline = Date().addingTimeInterval(5)
        while controller.phase.isActive && Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testUnresolvedNamesAndExplicitWebsitesOpenLuckySearchWithoutPlanning() async throws {
        for command in ["open the Hacker News website", "open Hacker News site", "open Hacker News page", "open Hacker News"] {
            let router = AgentSessionControllerTests.FakeRouter(specs: [])
            let controller = AgentSessionController(router: router, plannerFactory: { nil }, resolveApp: resolveTelegramFixture)
            controller.handleCommand(command)
            await waitUntilFinished(controller)
            XCTAssertEqual(router.executed, ["open_url"], command)
            let action = try NativeOpenAction.decode(toolName: "open_url", argumentsJSON: XCTUnwrap(router.arguments.first))
            let url = try XCTUnwrap(NativeOpenAction.luckySearchURL(for: "Hacker News"))
            XCTAssertEqual(action, .openURL(url: url, browser: nil))
            let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertEqual(query, [URLQueryItem(name: "q", value: "Hacker News"), URLQueryItem(name: "btnI", value: "1")])
            XCTAssertEqual(router.prepareCount, 0)
            XCTAssertFalse(controller.activityLog.contains { $0.hasPrefix("Failed") })
        }
    }

    func testInAppOpenGoesDirectlyToPlannerWithCurrentAndCarriedApp() async {
        let router = AgentSessionControllerTests.FakeRouter(specs: [])
        router.outputs["open_app"] = telegram.summary
        let planner = AgentSessionControllerTests.ContextualPlanner()
        let controller = AgentSessionController(
            router: router, plannerFactory: { planner }, resolveApp: resolveTelegramFixture, isAppRunning: { _ in true },
            isListeningSessionActive: { true }
        )
        controller.handleCommand("open Telegram and open Saved Messages")
        await waitUntilFinished(controller)
        XCTAssertEqual(router.executed, ["open_app"])
        XCTAssertEqual(planner.calls.last?.task, "open Saved Messages")
        XCTAssertEqual(planner.calls.last?.context?.currentApp, telegram)
        XCTAssertFalse(controller.activityLog.contains { $0.hasPrefix("Failed") })

        controller.handleCommand("open Saved Messages")
        await waitUntilFinished(controller)
        XCTAssertEqual(router.executed, ["open_app"])
        XCTAssertEqual(planner.calls.count, 2)
        XCTAssertEqual(planner.calls.last?.context?.currentApp, telegram)
        XCTAssertFalse(controller.activityLog.contains { $0.hasPrefix("Failed") })

        controller.handleCommand("open the Hacker News website")
        await waitUntilFinished(controller)
        XCTAssertEqual(router.executed, ["open_app", "open_url"], "An explicit website wins over the carried app.")
    }

    func testAppAdjectivesAndFuzzyMatchesResolveBeforeWebFallback() {
        let notes = URL(fileURLWithPath: "/fixture/Notes.app")
        let resolver = AppResolver(directories: [URL(fileURLWithPath: "/fixture")], applicationsInDirectory: { _ in [notes] })
        for name in ["the new Notes app", "my Notes", "that Notes app", "new nodes"] {
            XCTAssertEqual(resolver.resolve(name, fuzzy: true), notes)
            let action = NativeClauseRouter.resolvingOpen(.openApp(name: name), context: .init(
                resolveApp: { resolver.resolve($0, fuzzy: true) }, isRunning: { _ in false }
            ))
            XCTAssertEqual(action, .openApp(name: name))
        }
    }
}
