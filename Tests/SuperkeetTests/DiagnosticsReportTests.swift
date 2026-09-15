import XCTest
@testable import Superkeet

final class DiagnosticsReportTests: XCTestCase {
    private func input(
        stderr: String? = nil,
        issue: String? = nil,
        servers: [MCPServerDiagnostic] = []
    ) -> DiagnosticsReportInput {
        DiagnosticsReportInput(
            appVersion: "1.7.0 (1.7.0)",
            osVersion: "Version 26.0",
            generatedAt: Date(timeIntervalSince1970: 0),
            readinessStatus: "Ready to record",
            readinessIssues: [],
            daemonState: "idle",
            runtimeIssue: issue,
            stderrExcerpt: stderr,
            mcpServers: servers
        )
    }

    func testRendersCoreFields() {
        let text = DiagnosticsReport.render(
            input(servers: [MCPServerDiagnostic(name: "browser", state: "Connected", toolCount: 4)])
        )
        XCTAssertTrue(text.contains("Superkeet Diagnostics"))
        XCTAssertTrue(text.contains("App version: 1.7.0 (1.7.0)"))
        XCTAssertTrue(text.contains("Status: Ready to record"))
        XCTAssertTrue(text.contains("Issues: none"))
        XCTAssertTrue(text.contains("Daemon: idle"))
        XCTAssertTrue(text.contains("browser: Connected (4 tools)"))
    }

    func testRendersIssuesAndNoServers() {
        var value = input()
        value.readinessIssues = ["microphone", "accessibility"]
        value.mcpServers = []
        let text = DiagnosticsReport.render(value)
        XCTAssertTrue(text.contains("Issues: microphone, accessibility"))
        XCTAssertTrue(text.contains("- none configured"))
    }

    func testRedactsSecretsFromEngineLog() {
        let text = DiagnosticsReport.render(input(stderr: "Authorization: Bearer abc123.def-456"))
        XCTAssertFalse(text.contains("abc123.def-456"))
        XCTAssertTrue(text.contains("***"))
    }
}
