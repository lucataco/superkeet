import SwiftUI
import os.log

private let advancedTabLog = Logger(subsystem: "com.superkeet.app", category: "AdvancedTab")

struct RecordingTabView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var parakeetService = ParakeetService.shared
    @State private var availableDevices: [String] = []
    @State private var deviceChangeStatus: String?

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabHeader(
                title: "Advanced",
                subtitle: "Audio input, phrase replacements, engine behavior, and Actions Mode limits."
            )

            Form {
                Section {
                    Picker("Microphone", selection: $settings.audioInputDevice) {
                        Text("System Default").tag("")
                        ForEach(availableDevices, id: \.self) { device in
                            Text(device).tag(device)
                        }
                        if !settings.audioInputDevice.isEmpty, !availableDevices.contains(settings.audioInputDevice) {
                            Text("\(settings.audioInputDevice) (Unavailable)").tag(settings.audioInputDevice)
                        }
                    }
                    Button(action: refreshDevices) {
                        Label("Refresh Devices", systemImage: "arrow.clockwise")
                    }
                } header: {
                    Text("Audio Input")
                } footer: {
                    if let deviceChangeStatus {
                        Text(deviceChangeStatus).foregroundStyle(.secondary)
                    } else {
                        Text("Leave as System Default to use your Mac's default input device. The speech engine restarts automatically when you change this.")
                    }
                }

                PhraseReplacementsView()

                Section {
                    HStack {
                        TextField("Default", text: $settings.modelDirectory)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.allowsMultipleSelection = false
                            if panel.runModal() == .OK, let url = panel.url {
                                settings.modelDirectory = url.path
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
                    Text("Stopping the speech engine frees about a gigabyte of memory. It restarts automatically on your next recording, which adds a few seconds.")
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
            }
            .formStyle(.grouped)
        }
        .onAppear(perform: refreshDevices)
        .onChange(of: settings.modelDirectory) {
            ModelProvisioning.shared.refreshInstalledState()
        }
        .onChange(of: settings.audioInputDevice) {
            applyMicrophoneChange()
        }
    }

    private func refreshDevices() {
        dispatchPrecondition(condition: .onQueue(.main))
        availableDevices = AudioInputDeviceResolver.availableDeviceNames()
    }

    /// The engine opens its input device at launch, so a new selection needs a restart. Do it for
    /// the user instead of telling them to, but never interrupt a take in progress.
    private func applyMicrophoneChange() {
        guard settings.isDaemonRunning else { return }
        guard parakeetService.daemonState == .idle else {
            deviceChangeStatus = "The new microphone will be used after the current recording finishes and the engine restarts."
            return
        }
        deviceChangeStatus = "Restarting the speech engine with the new microphone…"
        Task {
            do {
                try await parakeetService.restartDaemon()
                deviceChangeStatus = nil
            } catch {
                advancedTabLog.error("Failed to restart engine after microphone change: \(error.localizedDescription)")
                deviceChangeStatus = "Couldn't restart the speech engine: \(error.localizedDescription)"
            }
        }
    }
}
