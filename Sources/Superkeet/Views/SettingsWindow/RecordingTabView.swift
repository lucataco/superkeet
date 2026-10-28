import SwiftUI
import os.log

private let advancedTabLog = Logger(subsystem: "com.superkeet.app", category: "AdvancedTab")

struct RecordingTabView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var parakeetService = ParakeetService.shared
    /// The folder as typed. It only becomes the model folder on Return, focus loss or Browse, so a
    /// half-typed path never becomes the place the engine downloads ~670 MB into.
    @State private var modelDirectoryDraft = ""
    @FocusState private var modelDirectoryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabHeader(
                title: "Advanced",
                subtitle: subtitle
            )

            Form {
                PhraseReplacementsView()

                Section {
                    HStack {
                        TextField("Default", text: $modelDirectoryDraft)
                            .textFieldStyle(.roundedBorder)
                            .focused($modelDirectoryFocused)
                            .onSubmit(commitModelDirectory)
                        Button("Browse…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.allowsMultipleSelection = false
                            if panel.runModal() == .OK, let url = panel.url {
                                modelDirectoryDraft = url.path
                                commitModelDirectory()
                            }
                        }
                    }
                } header: {
                    Text("Model Directory")
                } footer: {
                    Text("Leave empty to use the default location (~/Library/Application Support/parakeet/models/parakeet-tdt-0.6b-v3). Superkeet downloads the model here automatically on first run.")
                }

                Section {
                    Picker("Stop engine after inactivity", selection: $settings.idleTimeoutMinutes) {
                        Text("Never").tag(0)
                        Text("5 minutes").tag(5)
                        Text("15 minutes").tag(15)
                        Text("30 minutes").tag(30)
                        Text("60 minutes").tag(60)
                    }
                } header: {
                    Text("Engine")
                } footer: {
                    Text("Stopping the speech engine frees about 1.8 GB of memory. It restarts automatically on your next recording, which takes about a second.")
                }

                if AppleIntelligenceAvailability.osSupportsActionsMode {
                    Section {
                        Stepper(
                            "Maximum steps per command: \(settings.actionMaxSteps)",
                            value: $settings.actionMaxSteps,
                            in: 1...50
                        )
                        Stepper(
                            "Tool call timeout: \(settings.actionTimeoutSeconds)s",
                            value: $settings.actionTimeoutSeconds,
                            in: 15...600,
                            step: 15
                        )
                        Stepper(
                            "Command deadline: \(settings.actionRunDeadlineSeconds)s",
                            value: $settings.actionRunDeadlineSeconds,
                            in: 30...900,
                            step: 30
                        )
                    } header: {
                        Text("Actions Mode Limits")
                    } footer: {
                        Text("Safety rails for a runaway command. The defaults suit most MCP servers.")
                    }
                }

                TroubleshootingSection()
            }
            .formStyle(.grouped)
        }
        .onAppear {
            modelDirectoryDraft = settings.modelDirectory
        }
        .onChange(of: modelDirectoryFocused) { _, focused in
            if !focused { commitModelDirectory() }
        }
        .onChange(of: settings.modelDirectory) {
            ModelProvisioning.shared.refreshInstalledState()
        }
    }

    private var subtitle: String {
        AppleIntelligenceAvailability.osSupportsActionsMode
            ? "Phrase replacements, storage, Actions Mode limits, and troubleshooting."
            : "Phrase replacements, storage, and troubleshooting."
    }

    private func commitModelDirectory() {
        let trimmed = modelDirectoryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        modelDirectoryDraft = trimmed
        guard trimmed != settings.modelDirectory else { return }
        advancedTabLog.info("Model directory changed")
        settings.modelDirectory = trimmed
        parakeetService.requestEngineRestartForSettingsChange()
    }
}
