import Foundation

struct MCPServerDiagnostic: Equatable {
    let name: String
    let state: String
    let toolCount: Int
}

struct DiagnosticsReportInput: Equatable {
    var appVersion: String
    var osVersion: String
    var generatedAt: Date
    var readinessStatus: String
    var readinessIssues: [String]
    var daemonState: String
    var runtimeIssue: String?
    var stderrExcerpt: String?
    var mcpServers: [MCPServerDiagnostic]
}

enum DiagnosticsReport {
    static func render(_ input: DiagnosticsReportInput) -> String {
        var lines: [String] = []
        lines.append("Superkeet Diagnostics")
        lines.append("=====================")
        lines.append("Generated: \(iso8601(input.generatedAt))")
        lines.append("App version: \(input.appVersion)")
        lines.append("macOS: \(input.osVersion)")
        lines.append("")
        lines.append("Status: \(input.readinessStatus)")
        lines.append(
            input.readinessIssues.isEmpty
                ? "Issues: none"
                : "Issues: \(input.readinessIssues.joined(separator: ", "))"
        )
        lines.append("Daemon: \(input.daemonState)")

        if let issue = input.runtimeIssue, !issue.isEmpty {
            lines.append("Runtime issue: \(issue)")
        }
        if let stderr = input.stderrExcerpt, !stderr.isEmpty {
            lines.append("")
            lines.append("Engine log excerpt:")
            lines.append(stderr)
        }

        lines.append("")
        lines.append("MCP servers:")
        if input.mcpServers.isEmpty {
            lines.append("- none configured")
        } else {
            for server in input.mcpServers {
                lines.append("- \(server.name): \(server.state) (\(server.toolCount) tools)")
            }
        }

        return ActionRedactor.redactText(lines.joined(separator: "\n"))
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
