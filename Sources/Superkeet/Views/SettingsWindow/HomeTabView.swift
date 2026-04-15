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
    @State private var loginItemError: String?

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
                    title: statusTitle,
                    detail: statusDetail,
                    color: statusColor
                )

                VStack(alignment: .leading, spacing: 12) {
                    Text("Checklist")
                        .font(.title3)
                        .fontWeight(.semibold)

                    SetupRow(
                        title: "Setup verification",
                        detail: settings.hasVerifiedSetup
                            ? "Superkeet has passed its startup smoke test on this Mac."
                            : "Superkeet has not passed a full startup smoke test yet. Finish setup and run the daemon successfully to verify it.",
                        isComplete: settings.hasVerifiedSetup,
                        buttonTitle: settings.isDaemonRunning ? "Restart Daemon" : "Start Daemon"
                    ) {
                        runSetupVerification()
                    }

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
                            ? "Bundled Parakeet engine found at \(settings.parakeetBinaryPath)"
                            : "Bundled Parakeet engine not found at \(settings.parakeetBinaryPath)",
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
                        detail: accessibilityDetail,
                        isComplete: !readiness.issues.contains(.accessibility),
                        buttonTitle: "Open Settings"
                    ) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                        let granted = hotkeyManager.checkAccessibilitySilently()
                        hotkeyManager.accessibilityGranted = granted
                        if granted {
                            hotkeyManager.startListening()
                            if !hotkeyManager.isListening {
                                hotkeyManager.startRetryTimer()
                            }
                        }
                    }

                    SetupRow(
                        title: "Launch at Login",
                        detail: loginItemError
                            ?? (settings.launchAtLoginEnabled
                                ? "Superkeet will start automatically when you log in."
                                : "Optional. Start Superkeet automatically when you log in. Requires the installed .app bundle."),
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

                        Button(settings.isDaemonRunning ? "Restart Daemon" : "Start Daemon") {
                            Task {
                                do {
                                    if settings.isDaemonRunning {
                                        try await parakeetService.restartDaemon()
                                    } else {
                                        try await parakeetService.startDaemon()
                                    }
                                } catch {
                                    print("[HomeTab] Failed to start/restart daemon: \(error)")
                                }
                                refreshReadiness()
                            }
                        }
                        .buttonStyle(.bordered)
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
        if !settings.hasVerifiedSetup {
            if let issue = settings.runtimeIssue ?? parakeetService.lastUserFacingError {
                return issue
            }
            if readiness.isReadyForSelectedConfiguration(autoPasteEnabled: settings.autoPasteEnabled) {
                return "Setup is close, but Superkeet still needs one successful startup smoke test before it is marked complete."
            }
            if configuredOutputBlocked {
                return "Recording works, but setup stays unverified until Accessibility is granted because \(selectedOutputModeName) is selected."
            }
            return "Onboarding is skippable, but setup stays unverified until microphone, input, runtime, and engine checks pass together."
        }
        if let issue = settings.runtimeIssue ?? parakeetService.lastUserFacingError {
            return issue
        }
        if configuredOutputBlocked {
            return "Recording is ready, but \(selectedOutputModeName) needs Accessibility access before it can work reliably."
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

    private var statusTitle: String {
        if !settings.hasVerifiedSetup {
            return "Setup still needs verification"
        }
        if configuredOutputBlocked {
            return "Output setup required"
        }
        return readiness.statusText
    }

    private var statusColor: Color {
        if !settings.hasVerifiedSetup {
            return readiness.isReadyForSelectedConfiguration(autoPasteEnabled: settings.autoPasteEnabled) ? .orange : .red
        }
        if configuredOutputBlocked {
            return .orange
        }
        return readiness.isReadyForDaemon ? .green : .orange
    }

    private var configuredOutputBlocked: Bool {
        readiness.hasConfiguredOutputBlockingIssue(autoPasteEnabled: settings.autoPasteEnabled)
    }

    private var selectedOutputModeName: String {
        settings.autoPasteEnabled ? "Paste Automatically" : "Copy to Clipboard"
    }

    private var accessibilityDetail: String {
        if settings.autoPasteEnabled {
            return "Required for \(selectedOutputModeName) and still used for global shortcuts."
        }
        return "Optional for the current clipboard-first flow. Grant it to enable global shortcuts and automatic paste."
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
            loginItemError = nil
        } catch {
            print("[HomeTab] Failed to update login item: \(error)")
            loginItemError = "Failed to update login item. Make sure you're running the installed .app bundle."
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
                print("[HomeTab] Failed to verify setup: \(error)")
            }
            refreshReadiness()
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
    @StateObject private var recorderState = RecorderState()

    let onRecord: (Int, Int, String) -> Void
    let onCancel: () -> Void

    @State private var capturedName: String? = nil

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
                    teardown()
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
            recorderState.isActive = true
            startListening()
        }
        .onDisappear {
            teardown()
        }
    }

    private func startListening() {
        guard recorderState.eventMonitor == nil, recorderState.flagsMonitor == nil else { return }

        recorderState.eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard recorderState.isActive else { return event }
            let keyCode = Int(event.keyCode)

            // Escape cancels the recorder
            if keyCode == 53 {
                teardown()
                onCancel()
                return nil
            }

            // Pass through Cmd+Q and Cmd+W so the user can still quit/close
            if event.modifierFlags.contains(.command) && (keyCode == 12 || keyCode == 13) {
                return event
            }

            let modifiers = modifierFlagsToInt(event.modifierFlags)
            let name = displayNameForHotkey(keyCode: keyCode, modifierFlags: modifiers)
            applyHotkey(keyCode: keyCode, modifiers: modifiers, name: name)
            return nil
        }

        recorderState.flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            guard recorderState.isActive else { return event }
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
        stopListening()
        recorderState.pendingRecord?.cancel()

        let workItem = DispatchWorkItem { [recorderState] in
            guard recorderState.isActive else { return }
            recorderState.pendingRecord = nil
            onRecord(keyCode, modifiers, name)
        }
        recorderState.pendingRecord = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: workItem)
    }

    private func stopListening() {
        if let monitor = recorderState.eventMonitor {
            NSEvent.removeMonitor(monitor)
            recorderState.eventMonitor = nil
        }
        if let monitor = recorderState.flagsMonitor {
            NSEvent.removeMonitor(monitor)
            recorderState.flagsMonitor = nil
        }
    }

    private func teardown() {
        recorderState.isActive = false
        recorderState.pendingRecord?.cancel()
        recorderState.pendingRecord = nil
        stopListening()
    }

    private func modifierFlagsToInt(_ flags: NSEvent.ModifierFlags) -> Int {
        var result: UInt64 = 0
        if flags.contains(.command) { result |= CGEventFlags.maskCommand.rawValue }
        if flags.contains(.option) { result |= CGEventFlags.maskAlternate.rawValue }
        if flags.contains(.control) { result |= CGEventFlags.maskControl.rawValue }
        if flags.contains(.shift) { result |= CGEventFlags.maskShift.rawValue }
        return Int(result)
    }

    @MainActor
    private final class RecorderState: ObservableObject {
        var eventMonitor: Any?
        var flagsMonitor: Any?
        var pendingRecord: DispatchWorkItem?
        var isActive = false

        deinit {
            pendingRecord?.cancel()
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
            }
            if let monitor = flagsMonitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}
