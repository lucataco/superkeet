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
    @ObservedObject var modelProvisioning = ModelProvisioning.shared

    @State private var editingHotkey: EditingHotkey? = nil
    @State private var readiness = AppReadiness.current()
    @State private var loginItemError: String?
    @State private var shortcutError: String?
    @State private var showAllChecks = false

    enum EditingHotkey {
        case toggle
        case pushToTalk
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                StatsHeaderView()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Setup")
                        .font(.title)
                        .fontWeight(.bold)
                    Text("Confirm the app is ready and pick your shortcuts.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                StatusCard(
                    title: statusTitle,
                    detail: statusDetail,
                    color: statusColor
                )

                checklistSection

                Divider()

                VStack(alignment: .leading, spacing: 16) {
                    Text("Shortcuts")
                        .font(.title3)
                        .fontWeight(.semibold)

                    if let shortcutError {
                        Text(shortcutError)
                            .font(.caption)
                            .foregroundColor(.orange)
                    }

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
                                assignToggleHotkey(keyCode: keyCode, modifiers: modifiers, name: name)
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
                                assignPushToTalkHotkey(keyCode: keyCode, modifiers: modifiers, name: name)
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
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .cardStyle(padding: 10)
                    }
                }
            }
            .padding(24)
        }
        .onAppear {
            refreshReadiness()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshReadiness()
        }
        .onChange(of: modelProvisioning.state) {
            refreshReadiness()
        }
    }

    // MARK: - Checklist

    private var checks: [SetupCheck] {
        [
            SetupCheck(
                title: "Setup verification",
                detail: settings.hasVerifiedSetup
                    ? "Startup test passed."
                    : "Run the daemon once to verify.",
                isComplete: settings.hasVerifiedSetup,
                buttonTitle: settings.isDaemonRunning ? "Restart Daemon" : "Start Daemon",
                action: { runSetupVerification() }
            ),
            SetupCheck(
                title: "Microphone access",
                detail: microphoneDetail,
                isComplete: !readiness.issues.contains(.microphone),
                buttonTitle: microphoneButtonTitle,
                action: { openMicrophoneSettings() }
            ),
            SetupCheck(
                title: "Speech engine",
                detail: readiness.diagnostics.engineBinaryExists ? "Bundled engine found." : "Bundled engine not found.",
                isComplete: !readiness.issues.contains(.engine),
                buttonTitle: "Refresh",
                action: { refreshReadiness() }
            ),
            SetupCheck(
                title: "Speech model",
                detail: modelCheckDetail,
                isComplete: !readiness.issues.contains(.model),
                buttonTitle: modelCheckButtonTitle,
                action: { downloadModel() }
            ),
            SetupCheck(
                title: "Input device",
                detail: inputDeviceDetail,
                isComplete: !readiness.issues.contains(.inputDevice),
                buttonTitle: "Refresh",
                action: { refreshReadiness() }
            ),
            SetupCheck(
                title: "Runtime directory",
                detail: runtimeDirectoryDetail,
                isComplete: !readiness.issues.contains(.runtimeDirectory),
                buttonTitle: "Refresh",
                action: { refreshReadiness() }
            ),
            SetupCheck(
                title: "Accessibility access",
                detail: accessibilityDetail,
                isComplete: !readiness.issues.contains(.accessibility),
                buttonTitle: "Open Settings",
                action: { openAccessibilitySettings() }
            ),
            SetupCheck(
                title: "Launch at Login",
                detail: loginItemError
                    ?? (settings.launchAtLoginEnabled ? "Starts automatically at login." : "Optional. Start at login."),
                isComplete: settings.launchAtLoginEnabled,
                buttonTitle: settings.launchAtLoginEnabled ? "Disable" : "Enable",
                action: { toggleLaunchAtLogin() }
            )
        ]
    }

    @ViewBuilder
    private var checklistSection: some View {
        let allChecks = checks
        let incomplete = allChecks.filter { !$0.isComplete }
        let allComplete = incomplete.isEmpty
        let hasCompleteItems = incomplete.count < allChecks.count

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Checklist")
                    .font(.title3)
                    .fontWeight(.semibold)
                Spacer()
                if allComplete || hasCompleteItems {
                    Button(checklistToggleLabel(allComplete: allComplete)) {
                        withAnimation(.easeInOut(duration: 0.15)) { showAllChecks.toggle() }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }

            if allComplete {
                ReadyRow(count: allChecks.count)
                if showAllChecks {
                    checkRows(allChecks)
                }
            } else {
                checkRows(showAllChecks ? allChecks : incomplete)
            }
        }
    }

    @ViewBuilder
    private func checkRows(_ items: [SetupCheck]) -> some View {
        ForEach(items) { item in
            SetupRow(
                title: item.title,
                detail: item.detail,
                isComplete: item.isComplete,
                buttonTitle: item.buttonTitle,
                action: item.action
            )
        }
    }

    private func checklistToggleLabel(allComplete: Bool) -> String {
        if allComplete {
            return showAllChecks ? "Hide details" : "Show details"
        }
        return showAllChecks ? "Show issues only" : "Show all"
    }

    private var statusDetail: String {
        if !settings.hasVerifiedSetup {
            if let issue = settings.runtimeIssue ?? parakeetService.lastUserFacingError {
                return issue
            }
            if readiness.isReadyForSelectedConfiguration(autoPasteEnabled: settings.autoPasteEnabled) {
                return "Run the daemon once to finish setup."
            }
            if configuredOutputBlocked {
                return "Grant Accessibility to enable \(selectedOutputModeName)."
            }
            return "Finish the checks below to get started."
        }
        if let issue = settings.runtimeIssue ?? parakeetService.lastUserFacingError {
            return issue
        }
        if configuredOutputBlocked {
            return "\(selectedOutputModeName) needs Accessibility access."
        }
        if readiness.isReadyForBasicRecording {
            return readiness.issues.contains(.accessibility)
                ? "Ready to record. Grant Accessibility for global shortcuts."
                : "Ready to record."
        }
        if readiness.isReadyForDaemon {
            return "Grant microphone access and pick an input device."
        }
        return "Finish the checks below to get started."
    }

    private var statusTitle: String {
        if !settings.hasVerifiedSetup {
            return "Almost ready"
        }
        if configuredOutputBlocked {
            return "One step left"
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
            return "Required for \(selectedOutputModeName) and shortcuts."
        }
        return "Optional. Enables global shortcuts and auto-paste."
    }

    private var microphoneDetail: String {
        switch readiness.diagnostics.microphoneStatus {
        case .authorized:
            return "Access granted."
        case .denied:
            return "Denied. Re-enable it in System Settings."
        case .restricted:
            return "Restricted by the system."
        case .notDetermined:
            return "Not requested yet."
        @unknown default:
            return "Status unknown."
        }
    }

    private var microphoneButtonTitle: String {
        switch readiness.diagnostics.microphoneStatus {
        case .notDetermined:
            return "Request Access"
        case .authorized:
            return "Refresh"
        default:
            return "Open Settings"
        }
    }

    private var inputDeviceDetail: String {
        if readiness.diagnostics.availableInputDeviceNames.isEmpty {
            return "No input devices detected."
        }
        if !settings.audioInputDevice.isEmpty && !readiness.diagnostics.configuredInputDeviceFound {
            return "'\(settings.audioInputDevice)' is unavailable."
        }
        return "Available: \(readiness.diagnostics.availableInputDeviceNames.joined(separator: ", "))"
    }

    private var runtimeDirectoryDetail: String {
        readiness.diagnostics.runtimeDirectoryWritable
            ? "Writable."
            : "Not writable: \(readiness.diagnostics.runtimeDirectory.path)"
    }

    private var modelCheckDetail: String {
        switch modelProvisioning.state {
        case .installed:
            return "On-device model downloaded."
        case .downloading(let progress):
            return "Downloading… \(Int((progress.overallFraction * 100).rounded()))%"
        case .verifying:
            return "Verifying download…"
        case .checking:
            return "Checking…"
        case .failed(let message):
            return message
        case .notInstalled, .unknown:
            return "About 670 MB, one-time download."
        }
    }

    private var modelCheckButtonTitle: String {
        switch modelProvisioning.state {
        case .installed:
            return "Re-download"
        case .downloading, .verifying, .checking:
            return "Downloading…"
        default:
            return "Download"
        }
    }

    private func downloadModel() {
        if modelProvisioning.state.isInstalled {
            modelProvisioning.redownload()
        } else {
            modelProvisioning.startDownloadIfNeeded()
        }
    }

    private func refreshReadiness() {
        settings.syncLaunchAtLoginStatus()
        let refreshed = AppReadiness.current()
        readiness = refreshed
        syncAccessibilityState(isGranted: !refreshed.issues.contains(.accessibility))
        if settings.isDaemonRunning,
           refreshed.isReadyForSelectedConfiguration(autoPasteEnabled: settings.autoPasteEnabled) {
            settings.hasVerifiedSetup = true
        }
        parakeetService.lastDiagnosticsSummary = parakeetService.lastDiagnosticsSummary ?? diagnosticsSummary
    }

    private func syncAccessibilityState(isGranted: Bool) {
        hotkeyManager.accessibilityGranted = isGranted
        if isGranted {
            if !hotkeyManager.isListening {
                hotkeyManager.startListening()
            }
        } else if !hotkeyManager.isListening {
            hotkeyManager.startRetryTimer()
        }
    }

    private func assignToggleHotkey(keyCode: Int, modifiers: Int, name: String) {
        guard validateShortcutDoesNotMatchPushToTalk(keyCode: keyCode, modifiers: modifiers) else { return }

        settings.toggleHotkeyKeyCode = keyCode
        settings.toggleHotkeyModifierFlags = modifiers
        settings.toggleHotkeyDisplayName = name
        shortcutError = nil
        editingHotkey = nil
    }

    private func assignPushToTalkHotkey(keyCode: Int, modifiers: Int, name: String) {
        guard validateShortcutDoesNotMatchToggle(keyCode: keyCode, modifiers: modifiers) else { return }

        settings.pttHotkeyKeyCode = keyCode
        settings.pttHotkeyModifierFlags = modifiers
        settings.pttHotkeyDisplayName = name
        shortcutError = nil
        editingHotkey = nil
    }

    private func validateShortcutDoesNotMatchPushToTalk(keyCode: Int, modifiers: Int) -> Bool {
        validateShortcut(
            keyCode: keyCode,
            modifiers: modifiers,
            againstKeyCode: settings.pttHotkeyKeyCode,
            againstModifiers: settings.pttHotkeyModifierFlags
        )
    }

    private func validateShortcutDoesNotMatchToggle(keyCode: Int, modifiers: Int) -> Bool {
        validateShortcut(
            keyCode: keyCode,
            modifiers: modifiers,
            againstKeyCode: settings.toggleHotkeyKeyCode,
            againstModifiers: settings.toggleHotkeyModifierFlags
        )
    }

    private func validateShortcut(
        keyCode: Int,
        modifiers: Int,
        againstKeyCode: Int,
        againstModifiers: Int
    ) -> Bool {
        guard !hotkeyAssignmentsConflict(
            firstKeyCode: keyCode,
            firstModifiers: modifiers,
            secondKeyCode: againstKeyCode,
            secondModifiers: againstModifiers
        ) else {
            shortcutError = "Toggle Recording and Push to Talk cannot use the same shortcut."
            editingHotkey = nil
            return false
        }

        return true
    }

    private func toggleLaunchAtLogin() {
        settings.syncLaunchAtLoginStatus()
        let newValue = SMAppService.mainApp.status != .enabled
        do {
            if newValue {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            settings.syncLaunchAtLoginStatus()
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
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async {
                    refreshReadiness()
                }
            }
        case .authorized:
            refreshReadiness()
        default:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func openAccessibilitySettings() {
        _ = hotkeyManager.checkAccessibility()
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
        .cardStyle()
    }
}

// MARK: - Checklist model

private struct SetupCheck: Identifiable {
    var id: String { title }
    let title: String
    let detail: String
    let isComplete: Bool
    let buttonTitle: String
    let action: () -> Void
}

private struct ReadyRow: View {
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.system(size: 18))
            VStack(alignment: .leading, spacing: 2) {
                Text("Everything's ready")
                    .font(.system(size: 13, weight: .medium))
                Text("All \(count) checks passed. You're set to record.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .cardStyle()
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
        .cardStyle()
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
