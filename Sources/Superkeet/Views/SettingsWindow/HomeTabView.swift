import SwiftUI
import Carbon
import AVFoundation
import AppKit
import ServiceManagement

/// Setup tab focused on first-run clarity and the single primary shortcut.
struct HomeTabView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var parakeetService = ParakeetService.shared
    @ObservedObject var hotkeyManager = HotkeyManager.shared

    @State private var editingHotkey: EditingHotkey? = nil
    @State private var readiness = AppReadiness.current()

    enum EditingHotkey {
        case toggle
        case pushToTalk
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Setup")
                        .font(.title)
                        .fontWeight(.bold)
                    Text("Keep first run simple: confirm the app is ready, pick your shortcuts, and run a quick diagnostic before recording.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                StatusCard(
                    title: readiness.statusText,
                    detail: statusDetail,
                    color: readiness.isReadyForDaemon ? .green : .orange
                )

                VStack(alignment: .leading, spacing: 12) {
                    Text("Checklist")
                        .font(.title3)
                        .fontWeight(.semibold)

                    SetupRow(
                        title: "Microphone access",
                        detail: microphoneDetail,
                        isComplete: !readiness.issues.contains(.microphone),
                        buttonTitle: "Open Settings"
                    ) {
                        openMicrophoneSettings()
                    }

                    SetupRow(
                        title: "Speech engine",
                        detail: readiness.diagnostics.engineBinaryExists
                            ? "Parakeet engine found at \(settings.parakeetBinaryPath)"
                            : "Parakeet engine not found at \(settings.parakeetBinaryPath)",
                        isComplete: !readiness.issues.contains(.engine),
                        buttonTitle: "Refresh"
                    ) {
                        refreshReadiness()
                    }

                    SetupRow(
                        title: "Input device",
                        detail: inputDeviceDetail,
                        isComplete: !readiness.issues.contains(.inputDevice),
                        buttonTitle: "Refresh"
                    ) {
                        refreshReadiness()
                    }

                    SetupRow(
                        title: "Runtime directory",
                        detail: runtimeDirectoryDetail,
                        isComplete: !readiness.issues.contains(.runtimeDirectory),
                        buttonTitle: "Refresh"
                    ) {
                        refreshReadiness()
                    }

                    SetupRow(
                        title: "Accessibility access",
                        detail: "Optional. Needed for global shortcuts and automatic paste.",
                        isComplete: !readiness.issues.contains(.accessibility),
                        buttonTitle: "Open Settings"
                    ) {
                        hotkeyManager.checkAccessibility()
                    }

                    SetupRow(
                        title: "Launch at Login",
                        detail: settings.launchAtLoginEnabled
                            ? "Superkeet will start automatically when you log in."
                            : "Optional. Start Superkeet automatically when you log in. Requires the installed .app bundle.",
                        isComplete: settings.launchAtLoginEnabled,
                        buttonTitle: settings.launchAtLoginEnabled ? "Disable" : "Enable"
                    ) {
                        toggleLaunchAtLogin()
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 16) {
                    Text("Shortcuts")
                        .font(.title3)
                        .fontWeight(.semibold)

                    HotkeyRow(
                        title: "Toggle Recording",
                        description: "Press once to start, press again to stop",
                        displayName: settings.toggleHotkeyDisplayName,
                        isEditing: editingHotkey == .toggle,
                        onClickBadge: {
                            editingHotkey = editingHotkey == .toggle ? nil : .toggle
                        }
                    )

                    if editingHotkey == .toggle {
                        InteractiveHotkeyRecorder(
                            onRecord: { keyCode, modifiers, name in
                                settings.toggleHotkeyKeyCode = keyCode
                                settings.toggleHotkeyModifierFlags = modifiers
                                settings.toggleHotkeyDisplayName = name
                                editingHotkey = nil
                            },
                            onCancel: { editingHotkey = nil }
                        )
                    }

                    HotkeyRow(
                        title: "Push to Talk",
                        description: "Hold to record, release to stop",
                        displayName: settings.pttHotkeyDisplayName,
                        isEditing: editingHotkey == .pushToTalk,
                        onClickBadge: {
                            editingHotkey = editingHotkey == .pushToTalk ? nil : .pushToTalk
                        }
                    )

                    if editingHotkey == .pushToTalk {
                        InteractiveHotkeyRecorder(
                            onRecord: { keyCode, modifiers, name in
                                settings.pttHotkeyKeyCode = keyCode
                                settings.pttHotkeyModifierFlags = modifiers
                                settings.pttHotkeyDisplayName = name
                                editingHotkey = nil
                            },
                            onCancel: { editingHotkey = nil }
                        )
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Diagnostics")
                        .font(.title3)
                        .fontWeight(.semibold)

                    HStack(spacing: 12) {
                        Button("Refresh Status") {
                            refreshReadiness()
                        }
                        .buttonStyle(.bordered)

                        Button("Run Diagnostics") {
                            parakeetService.refreshDiagnostics()
                            refreshReadiness()
                        }
                        .buttonStyle(.bordered)

                        Button("Restart Daemon") {
                            Task {
                                do {
                                    try await parakeetService.restartDaemon()
                                } catch {
                                    print("[HomeTab] Failed to restart daemon: \(error)")
                                }
                                refreshReadiness()
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(!settings.isDaemonRunning)
                    }

                    if let issue = settings.runtimeIssue ?? parakeetService.lastUserFacingError {
                        Text(issue)
                            .font(.caption)
                            .foregroundColor(.orange)
                    }

                    if let startupStatus = parakeetService.startupStatusDetail {
                        Text("Daemon status: \(startupStatus)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if let diagnostics = parakeetService.lastDiagnosticsSummary {
                        Text(diagnostics)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.04))
                            .cornerRadius(10)
                    }
                }
            }
            .padding(24)
        }
        .onAppear {
            refreshReadiness()
        }
    }

    private var statusDetail: String {
        if let issue = settings.runtimeIssue ?? parakeetService.lastUserFacingError {
            return issue
        }
        if readiness.isReadyForBasicRecording {
            return readiness.issues.contains(.accessibility)
                ? "Recording is ready. Global automation will stay limited until Accessibility access is granted."
                : "Recording and basic output are ready."
        }
        if readiness.isReadyForDaemon {
            return "The daemon can start, but recording will fail until microphone access and an input device are available."
        }
        return "Finish the missing setup items below before relying on Superkeet."
    }

    private var microphoneDetail: String {
        switch readiness.diagnostics.microphoneStatus {
        case .authorized:
            return "Microphone access is granted."
        case .denied:
            return "Microphone access is denied. Superkeet cannot record until you re-enable it in System Settings."
        case .restricted:
            return "Microphone access is restricted by the system."
        case .notDetermined:
            return "Microphone access has not been requested yet."
        @unknown default:
            return "Microphone permission status is unknown."
        }
    }

    private var inputDeviceDetail: String {
        if readiness.diagnostics.availableInputDeviceNames.isEmpty {
            return "No input devices detected. Check macOS Sound settings and connected microphones."
        }
        if !settings.audioInputDevice.isEmpty && !readiness.diagnostics.configuredInputDeviceFound {
            return "Selected device '\(settings.audioInputDevice)' is unavailable. Available: \(readiness.diagnostics.availableInputDeviceNames.joined(separator: ", "))"
        }
        return "Available: \(readiness.diagnostics.availableInputDeviceNames.joined(separator: ", "))"
    }

    private var runtimeDirectoryDetail: String {
        let path = readiness.diagnostics.runtimeDirectory.path
        return readiness.diagnostics.runtimeDirectoryWritable
            ? "Writable runtime directory at \(path)"
            : "Superkeet cannot write to \(path)"
    }

    private func refreshReadiness() {
        readiness = AppReadiness.current()
        parakeetService.lastDiagnosticsSummary = parakeetService.lastDiagnosticsSummary ?? diagnosticsSummary
    }

    private func toggleLaunchAtLogin() {
        let newValue = !settings.launchAtLoginEnabled
        do {
            if newValue {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            settings.launchAtLoginEnabled = newValue
        } catch {
            print("[HomeTab] Failed to update login item: \(error)")
        }
    }

    private func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private var diagnosticsSummary: String {
        let devices = readiness.diagnostics.availableInputDeviceNames.isEmpty
            ? "none"
            : readiness.diagnostics.availableInputDeviceNames.joined(separator: ", ")
        return """
        Diagnostics:
        - Microphone: \(microphoneDetail)
        - Input devices: \(devices)
        - Engine path: \(settings.parakeetBinaryPath)
        - Runtime directory: \(readiness.diagnostics.runtimeDirectory.path)
        """
    }
}

private struct StatusCard: View {
    let title: String
    let detail: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
                .foregroundColor(.primary)
            Text(detail)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(color.opacity(0.2), lineWidth: 1)
        )
        .cornerRadius(12)
    }
}

private struct SetupRow: View {
    let title: String
    let detail: String
    let isComplete: Bool
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isComplete ? .green : .secondary)
                .font(.system(size: 18))
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(buttonTitle, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(10)
    }
}

// MARK: - Hotkey Row

struct HotkeyRow: View {
    let title: String
    let description: String
    let displayName: String
    let isEditing: Bool
    let onClickBadge: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: onClickBadge) {
                HotkeyBadge(displayName: displayName, isEditing: isEditing)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(10)
    }
}

struct HotkeyBadge: View {
    let displayName: String
    var isEditing: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Text(displayName)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
            if !isEditing {
                Image(systemName: "pencil")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isEditing ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.08))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isEditing ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.15), lineWidth: 1)
        )
    }
}

// MARK: - Interactive Hotkey Recorder

struct InteractiveHotkeyRecorder: View {
    let onRecord: (Int, Int, String) -> Void
    let onCancel: () -> Void

    @State private var capturedName: String? = nil
    @State private var eventMonitor: Any? = nil
    @State private var flagsMonitor: Any? = nil

    var body: some View {
        VStack(spacing: 10) {
            if let name = capturedName {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Set to: \(name)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.green)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Press any key combination...")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.accentColor)
                }
            }

            HStack {
                Button("⌥ Space") {
                    applyHotkey(keyCode: 49, modifiers: Int(CGEventFlags.maskAlternate.rawValue), name: "⌥ Space")
                }
                Button("fn") {
                    applyHotkey(keyCode: 63, modifiers: 0, name: "fn")
                }
                Button("⌃ Space") {
                    applyHotkey(keyCode: 49, modifiers: Int(CGEventFlags.maskControl.rawValue), name: "⌃ Space")
                }

                Spacer()

                Button("Cancel") {
                    cleanup()
                    onCancel()
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.05))
        .cornerRadius(10)
        .onAppear {
            startListening()
        }
        .onDisappear {
            cleanup()
        }
    }

    private func startListening() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = Int(event.keyCode)
            let modifiers = modifierFlagsToInt(event.modifierFlags)
            let name = displayNameForHotkey(keyCode: keyCode, modifierFlags: modifiers)
            applyHotkey(keyCode: keyCode, modifiers: modifiers, name: name)
            return nil
        }

        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let keyCode = Int(event.keyCode)
            if keyCode == 63 {
                applyHotkey(keyCode: 63, modifiers: 0, name: "fn")
                return nil
            }
            return event
        }
    }

    private func applyHotkey(keyCode: Int, modifiers: Int, name: String) {
        capturedName = name
        cleanup()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            onRecord(keyCode, modifiers, name)
        }
    }

    private func cleanup() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        if let monitor = flagsMonitor {
            NSEvent.removeMonitor(monitor)
            flagsMonitor = nil
        }
    }

    private func modifierFlagsToInt(_ flags: NSEvent.ModifierFlags) -> Int {
        var result: UInt64 = 0
        if flags.contains(.command) { result |= CGEventFlags.maskCommand.rawValue }
        if flags.contains(.option) { result |= CGEventFlags.maskAlternate.rawValue }
        if flags.contains(.control) { result |= CGEventFlags.maskControl.rawValue }
        if flags.contains(.shift) { result |= CGEventFlags.maskShift.rawValue }
        return Int(result)
    }
}
