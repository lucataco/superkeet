import SwiftUI
import Darwin
import os.log

private let recordingTabLog = Logger(subsystem: "com.superkeet.app", category: "RecordingTab")

/// Recording settings: audio device, model directory
struct RecordingTabView: View {
    @ObservedObject var settings = AppSettings.shared
    @StateObject private var refreshState = DeviceRefreshState()
    @State private var availableDevices: [String] = []
    @State private var isLoadingDevices: Bool = false

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
                    }
                    Button {
                        refreshDevices()
                    } label: {
                        Label("Refresh Devices", systemImage: "arrow.clockwise")
                    }
                    .disabled(isLoadingDevices)
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
        .onAppear {
            refreshDevices()
        }
        .onDisappear {
            refreshState.cancel()
            isLoadingDevices = false
        }
        .onChange(of: settings.modelDirectory) {
            ModelProvisioning.shared.refreshInstalledState()
        }
    }

    private func refreshDevices() {
        let generation = refreshState.beginRefresh()
        isLoadingDevices = true
        let binaryPath = settings.parakeetBinaryPath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["devices"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        refreshState.track(process: process, for: generation)

        Task.detached(priority: .userInitiated) {
            let shouldStart = await MainActor.run {
                refreshState.shouldRun(process: process, generation: generation)
            }
            guard shouldStart else { return }

            var devices: [String] = []
            do {
                devices = try runDeviceQuery(process: process, pipe: pipe)
            } catch {
                let wasCancelled = await MainActor.run {
                    !refreshState.shouldRun(process: process, generation: generation)
                }
                if !wasCancelled {
                    recordingTabLog.error("Failed to list devices: \(error.localizedDescription)")
                }
            }

            let resolvedDevices = devices
            await MainActor.run {
                guard refreshState.finish(process: process, generation: generation) else { return }
                self.availableDevices = resolvedDevices
                self.isLoadingDevices = false
            }
        }
    }

}

private func runDeviceQuery(process: Process, pipe: Pipe) throws -> [String] {
    try process.run()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global(qos: .utility).async {
        process.waitUntilExit()
        group.leave()
    }

    if group.wait(timeout: .now() + 5) == .timedOut {
        process.terminate()
        if group.wait(timeout: .now() + 1) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = group.wait(timeout: .now() + 1)
        }
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8) else { return [] }

    return output.components(separatedBy: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("Available") && !$0.hasPrefix("---") }
        .compactMap { line -> String? in
            if let parenRange = line.range(of: " (") {
                return String(line[line.startIndex..<parenRange.lowerBound])
            }
            return line
        }
}

@MainActor
private final class DeviceRefreshState: ObservableObject {
    private var generation: Int = 0
    private var activeProcess: Process?

    func beginRefresh() -> Int {
        generation += 1
        terminateActiveProcess()
        return generation
    }

    func track(process: Process, for generation: Int) {
        guard self.generation == generation else { return }
        activeProcess = process
    }

    func shouldRun(process: Process, generation: Int) -> Bool {
        self.generation == generation && activeProcess === process
    }

    func finish(process: Process, generation: Int) -> Bool {
        guard shouldRun(process: process, generation: generation) else { return false }
        activeProcess = nil
        return true
    }

    func cancel() {
        generation += 1
        terminateActiveProcess()
    }

    private func terminateActiveProcess() {
        guard let process = activeProcess else { return }
        activeProcess = nil
        guard process.isRunning else { return }
        process.terminate()
    }
}
