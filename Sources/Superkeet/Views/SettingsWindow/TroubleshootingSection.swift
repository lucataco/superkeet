import SwiftUI
import os.log

private let troubleshootingLog = Logger(subsystem: "com.superkeet.app", category: "Troubleshooting")

struct TroubleshootingSection: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var parakeetService = ParakeetService.shared
    @State private var diagnosticsCopied = false
    @State private var logExportError: String?

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button("Refresh") {
                        parakeetService.refreshDiagnostics()
                        SetupRefresh.run()
                    }

                    Button("Copy Diagnostics") {
                        DiagnosticsExporter.copyToClipboard()
                        diagnosticsCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            diagnosticsCopied = false
                        }
                    }

                    Button("Export Logs…") {
                        logExportError = LogExporter.exportWithSavePanel()
                    }
                    .help("Save diagnostics and Superkeet's log since launch to a text file for a bug report")

                    Button(settings.isDaemonRunning ? "Restart Speech Engine" : "Start Speech Engine") {
                        runSetupVerification()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if let issue = settings.runtimeIssue ?? parakeetService.lastUserFacingError {
                    Text(issue)
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                if let logExportError {
                    Text(logExportError)
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                if diagnosticsCopied {
                    Text("Diagnostics copied to the clipboard.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                DisclosureGroup("Diagnostic details") {
                    VStack(alignment: .leading, spacing: 8) {
                        if let startupStatus = parakeetService.startupStatusDetail {
                            Text("Status: \(startupStatus)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        if let diagnostics = parakeetService.lastDiagnosticsSummary {
                            Text(diagnostics)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.caption)
            }
            .padding(.vertical, 2)
        } header: {
            Text("Troubleshooting")
        }
    }

    private func runSetupVerification() {
        Task {
            do {
                if settings.isDaemonRunning {
                    try await parakeetService.restartDaemon()
                } else {
                    try await parakeetService.startDaemon()
                }
            } catch {
                troubleshootingLog.error("Failed to verify setup: \(error.localizedDescription, privacy: .public)")
            }
            SetupRefresh.run()
        }
    }
}
