import Foundation
import os.log

private let diagnosticsLog = Logger(subsystem: "com.superkeet.app", category: "DiagnosticsExporter")

@MainActor
enum DiagnosticsExporter {
    static func input() -> DiagnosticsReportInput {
        let settings = AppSettings.shared
        let service = ParakeetService.shared
        let readiness = AppReadiness.current(settings: settings)
        let manager = MCPClientManager.shared

        let servers = MCPServerConfigStore.shared.servers.map { server in
            MCPServerDiagnostic(
                name: server.trimmedName,
                state: manager.state(for: server.id).label,
                toolCount: manager.tools(for: server.id).count
            )
        }

        return DiagnosticsReportInput(
            appVersion: AppVersion.current.displayString,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            generatedAt: Date(),
            readinessStatus: readiness.statusText,
            readinessIssues: readiness.issues.map(\.rawValue),
            daemonState: service.daemonState.rawValue,
            runtimeIssue: settings.runtimeIssue ?? service.lastUserFacingError,
            stderrExcerpt: service.lastDiagnosticsSummary,
            mcpServers: servers
        )
    }

    static func currentReport() -> String {
        DiagnosticsReport.render(input())
    }

    @discardableResult
    static func copyToClipboard() -> String {
        let report = currentReport()
        PasteService.shared.copyToClipboard(report)
        diagnosticsLog.info("Copied diagnostics report to the clipboard")
        return report
    }
}
