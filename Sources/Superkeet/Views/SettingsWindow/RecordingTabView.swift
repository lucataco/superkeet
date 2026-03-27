import SwiftUI

/// Recording settings: audio device, model directory
struct RecordingTabView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var availableDevices: [String] = []
    @State private var isLoadingDevices: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Recording")
                    .font(.title)
                    .fontWeight(.bold)

                // Audio Input Device
                VStack(alignment: .leading, spacing: 8) {
                    Label("Audio Input Device", systemImage: "mic.fill")
                        .font(.headline)

                    HStack {
                        Picker("", selection: $settings.audioInputDevice) {
                            Text("System Default").tag("")
                            ForEach(availableDevices, id: \.self) { device in
                                Text(device).tag(device)
                            }
                        }
                        .labelsHidden()

                        Button(action: refreshDevices) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(isLoadingDevices)
                    }

                    Text("Select the microphone to use for recording. Leave as System Default to use your Mac's default input device. Changes take effect after restarting the daemon.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Divider()

                // Model Directory
                VStack(alignment: .leading, spacing: 8) {
                    Label("Model Directory", systemImage: "folder.fill")
                        .font(.headline)

                    HStack {
                        TextField("Default", text: $settings.modelDirectory)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse...") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.allowsMultipleSelection = false
                            if panel.runModal() == .OK, let url = panel.url {
                                settings.modelDirectory = url.path
                            }
                        }
                    }

                    Text("Leave empty to use the default model directory (~~/Library/Application Support/parakeet/models/). Changes take effect after restarting the daemon.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Divider()

                // Idle Daemon Timeout
                VStack(alignment: .leading, spacing: 8) {
                    Label("Idle Daemon Timeout", systemImage: "moon.zzz")
                        .font(.headline)

                    Picker("Stop daemon after inactivity:", selection: $settings.idleTimeoutMinutes) {
                        Text("Disabled").tag(0)
                        Text("5 minutes").tag(5)
                        Text("15 minutes").tag(15)
                        Text("30 minutes").tag(30)
                        Text("60 minutes").tag(60)
                    }
                    .pickerStyle(.menu)

                    Text("Automatically stop the speech engine after a period of inactivity to reclaim memory. The engine restarts automatically when you start recording.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding(24)
        }
        .onAppear {
            refreshDevices()
        }
    }

    private func refreshDevices() {
        isLoadingDevices = true
        let settings = self.settings

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: settings.parakeetBinaryPath)
            process.arguments = ["devices"]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            var devices: [String] = []

            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    // Parse device names from output
                    // Format is typically: "  Device Name (channels, rate, format)"
                    devices = output.components(separatedBy: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty && !$0.hasPrefix("Available") && !$0.hasPrefix("---") }
                        .compactMap { line -> String? in
                            // Extract just the device name before any parenthetical info
                            if let parenRange = line.range(of: " (") {
                                return String(line[line.startIndex..<parenRange.lowerBound])
                            }
                            return line
                        }
                }
            } catch {
                print("[RecordingTab] Failed to list devices: \(error)")
            }

            DispatchQueue.main.async {
                self.availableDevices = devices
                self.isLoadingDevices = false
            }
        }
    }
}
