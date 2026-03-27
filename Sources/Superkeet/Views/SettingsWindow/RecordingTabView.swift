import SwiftUI

/// Recording settings: audio device, VAD threshold, silence timeout
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

                    Text("Select the microphone to use for recording. Leave as System Default to use your Mac's default input device.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Divider()

                // VAD Sensitivity
                VStack(alignment: .leading, spacing: 8) {
                    Label("Voice Detection Sensitivity", systemImage: "waveform.badge.magnifyingglass")
                        .font(.headline)

                    HStack {
                        Text("Less Sensitive")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Slider(value: $settings.vadThreshold, in: 0.1...0.9, step: 0.05)
                        Text("More Sensitive")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Text("Current: \(String(format: "%.2f", settings.vadThreshold)) — Higher values require clearer speech to start recording. Lower values are more sensitive to quiet speech.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Divider()

                // Silence Timeout
                VStack(alignment: .leading, spacing: 8) {
                    Label("Silence Timeout", systemImage: "clock.badge.xmark")
                        .font(.headline)

                    HStack {
                        Text("0.5s")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Slider(
                            value: Binding(
                                get: { Double(settings.silenceTimeoutMs) },
                                set: { settings.silenceTimeoutMs = Int($0) }
                            ),
                            in: 500...5000,
                            step: 100
                        )
                        Text("5.0s")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Text("Current: \(String(format: "%.1f", Double(settings.silenceTimeoutMs) / 1000.0))s — How long to wait after you stop speaking before ending the recording. Shorter values respond faster; longer values allow for longer pauses.")
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

                    Text("Leave empty to use the default model directory (~~/Library/Application Support/parakeet/models/)")
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
