import SwiftUI

struct RecordingTabView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var availableDevices: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabHeader(
                title: "Advanced",
                subtitle: "Fine-tune audio input, model location, and engine behavior."
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
                    Text("Leave as System Default to use your Mac's default input device. Changes take effect after restarting the daemon.")
                }

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
                    Picker("Stop daemon after inactivity", selection: $settings.idleTimeoutMinutes) {
                        Text("Disabled").tag(0)
                        Text("5 minutes").tag(5)
                        Text("15 minutes").tag(15)
                        Text("30 minutes").tag(30)
                        Text("60 minutes").tag(60)
                    }
                } header: {
                    Text("Engine")
                } footer: {
                    Text("Automatically stop the speech engine after a period of inactivity to reclaim memory. It restarts automatically when you start recording.")
                }
            }
            .formStyle(.grouped)
        }
        .onAppear(perform: refreshDevices)
        .onChange(of: settings.modelDirectory) {
            ModelProvisioning.shared.refreshInstalledState()
        }
    }

    private func refreshDevices() {
        dispatchPrecondition(condition: .onQueue(.main))
        availableDevices = AudioInputDeviceResolver.availableDeviceNames()
    }
}
