import SwiftUI
import os.log

private let microphoneLog = Logger(subsystem: "com.superkeet.app", category: "Microphone")

struct MicrophoneSection: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var parakeetService = ParakeetService.shared
    @State private var availableDevices: [String] = []
    @State private var deviceChangeStatus: String?

    var body: some View {
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
            Text("Microphone")
        } footer: {
            if let deviceChangeStatus {
                Text(deviceChangeStatus).foregroundStyle(.secondary)
            } else {
                Text("Leave as System Default to use your Mac's default input device. Changes apply to your next recording.")
            }
        }
        .onAppear {
            refreshDevices()
        }
        .onChange(of: settings.audioInputDevice) {
            applyMicrophoneChange()
        }
        .onChange(of: parakeetService.daemonState) { _, state in
            guard state == .idle, !parakeetService.hasPendingEngineRestart else { return }
            deviceChangeStatus = nil
        }
    }

    private func refreshDevices() {
        dispatchPrecondition(condition: .onQueue(.main))
        availableDevices = AudioInputDeviceResolver.availableDeviceNames()
    }

    private func applyMicrophoneChange() {
        switch parakeetService.requestEngineRestartForSettingsChange() {
        case .notNeeded:
            deviceChangeStatus = nil
        case .restarting:
            microphoneLog.info("Restarting engine for microphone change")
            deviceChangeStatus = "Switching to the new microphone…"
        case .deferredUntilIdle:
            microphoneLog.info("Microphone change deferred until the current take finishes")
            deviceChangeStatus = "The new microphone will be used as soon as the current recording finishes."
        }
    }
}
