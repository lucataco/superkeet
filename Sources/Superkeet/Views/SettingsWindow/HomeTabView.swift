import SwiftUI
import AVFoundation
import AppKit
import ServiceManagement
import os.log

private let homeTabLog = Logger(subsystem: "com.superkeet.app", category: "HomeTab")

/// Setup tab focused on first-run clarity and recording shortcuts.
struct HomeTabView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var parakeetService = ParakeetService.shared
    @ObservedObject var hotkeyManager = HotkeyManager.shared
    @ObservedObject var modelProvisioning = ModelProvisioning.shared

    @State private var editingHotkey: EditingHotkey?
    @State private var readiness = AppReadiness.current()
    @State private var loginItemError: String?
    @State private var shortcutError: String?
    @State private var showAllChecks = false

    enum EditingHotkey {
        case toggle
        case pushToTalk
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabHeader(
                title: "General",
                subtitle: "Set up Superkeet, choose how it looks, and pick your shortcuts."
            )

            Form {
                Section {
                    StatsHeaderView()
                        .padding(.vertical, 4)
                } header: {
                    Text("Your Dictation")
                }

                Section {
                    Picker(selection: $settings.appearancePreference) {
                        ForEach(AppearancePreference.allCases) { preference in
                            Text(preference.label).tag(preference)
                        }
                    } label: {
                        rowLabel("Appearance", "Match the system, or force light or dark")
                    }
                    .onChange(of: settings.appearancePreference) {
                        settings.applyAppearancePreference()
                    }

                    Toggle(isOn: launchAtLoginBinding) {
                        rowLabel(
                            "Launch at Login",
                            loginItemError ?? "Start Superkeet automatically when you sign in"
                        )
                    }
                } header: {
                    Text("Appearance & Behavior")
                }

                Section {
                    StatusCard(
                        title: statusTitle,
                        detail: statusDetail,
                        color: statusColor
                    )
                    .padding(.vertical, 2)

                    checklistContent
                } header: {
                    checklistHeader
                }

                Section {
                    shortcutsContent
                } header: {
                    Text("Shortcuts")
                } footer: {
                    if let shortcutError {
                        Text(shortcutError).foregroundStyle(.orange)
                    }
                }

                Section {
                    diagnosticsContent
                } header: {
                    Text("Diagnostics")
                }
            }
            .formStyle(.grouped)
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
            )
        ]
    }

    // MARK: - Derived checklist state

    private var requiredChecks: [SetupCheck] {
        checks.filter { !$0.isOptional }
    }

    private var incompleteRequiredChecks: [SetupCheck] {
        requiredChecks.filter { !$0.isComplete }
    }

    private var allChecksComplete: Bool {
        incompleteRequiredChecks.isEmpty
    }

    @ViewBuilder
    private var checklistHeader: some View {
        let canToggle = allChecksComplete || incompleteRequiredChecks.count < requiredChecks.count
        HStack {
            Text("Setup Checklist")
            Spacer()
            if canToggle {
                Button(checklistToggleLabel(allComplete: allChecksComplete)) {
                    withAnimation(.easeInOut(duration: 0.15)) { showAllChecks.toggle() }
                }
                .buttonStyle(.link)
                .font(.caption)
                .textCase(nil)
            }
        }
    }

    @ViewBuilder
    private var checklistContent: some View {
        if allChecksComplete {
            ReadyRow(count: requiredChecks.count)
            if showAllChecks {
                checkRows(checks)
            }
        } else {
            checkRows(showAllChecks ? checks : incompleteRequiredChecks)
        }
    }

    @ViewBuilder
    private var shortcutsContent: some View {
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

    @ViewBuilder
    private var diagnosticsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button("Refresh Status") {
                    refreshReadiness()
                }

                Button("Run Diagnostics") {
                    parakeetService.refreshDiagnostics()
                    refreshReadiness()
                }

                Button(settings.isDaemonRunning ? "Restart Daemon" : "Start Daemon") {
                    Task {
                        do {
                            if settings.isDaemonRunning {
                                try await parakeetService.restartDaemon()
                            } else {
                                try await parakeetService.startDaemon()
                            }
                        } catch {
                            homeTabLog.error("Failed to start/restart daemon: \(error.localizedDescription)")
                        }
                        refreshReadiness()
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if let issue = settings.runtimeIssue ?? parakeetService.lastUserFacingError {
                Text(issue)
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            DisclosureGroup("Diagnostic details") {
                VStack(alignment: .leading, spacing: 8) {
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
                    }
                }
                .padding(.top, 6)
            }
            .font(.caption)
        }
        .padding(.vertical, 2)
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { settings.launchAtLoginEnabled },
            set: { setLaunchAtLogin(enabled: $0) }
        )
    }

    private func rowLabel(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
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
            if isReadyForSelectedConfiguration {
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
        if readiness.needsModelDownload {
            return "Download the speech model to record."
        }
        if readiness.hasRecordingBlockingIssue {
            return "Grant microphone access and pick an input device."
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
        if !readiness.isReadyForDaemon {
            return "Setup required"
        }
        if readiness.needsModelDownload || readiness.hasRecordingBlockingIssue {
            return "Setup needs attention"
        }
        return readiness.statusText
    }

    private var statusColor: Color {
        if !settings.hasVerifiedSetup {
            return isReadyForSelectedConfiguration ? .orange : .red
        }
        if configuredOutputBlocked {
            return .orange
        }
        if !readiness.isReadyForDaemon {
            return .red
        }
        return isReadyForSelectedConfiguration ? .green : .orange
    }

    private var configuredOutputBlocked: Bool {
        readiness.hasConfiguredOutputBlockingIssue(autoPasteEnabled: settings.autoPasteEnabled)
    }

    private var isReadyForSelectedConfiguration: Bool {
        readiness.isReadyForSelectedConfiguration(autoPasteEnabled: settings.autoPasteEnabled)
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
        modelProvisioning.refreshInstalledState()
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

    private func setLaunchAtLogin(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            settings.syncLaunchAtLoginStatus()
            loginItemError = nil
        } catch {
            homeTabLog.error("Failed to update login item: \(error.localizedDescription)")
            loginItemError = "Failed to update login item. Make sure you're running the installed .app bundle."
            settings.syncLaunchAtLoginStatus()
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
                homeTabLog.error("Failed to verify setup: \(error.localizedDescription)")
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
            SystemSettingsLinks.openMicrophone()
        }
    }

    private func openAccessibilitySettings() {
        _ = hotkeyManager.checkAccessibility()
        SystemSettingsLinks.openAccessibility()
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
    }
}

// MARK: - Checklist model

private struct SetupCheck: Identifiable {
    var id: String { title }
    let title: String
    let detail: String
    let isComplete: Bool
    var isOptional: Bool = false
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
    }
}

// MARK: - Hotkey Row

private struct HotkeyRow: View {
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
    }
}

private struct HotkeyBadge: View {
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

private struct InteractiveHotkeyRecorder: View {
    @StateObject private var recorderState = RecorderState()

    let onRecord: (Int, Int, String) -> Void
    let onCancel: () -> Void

    @State private var capturedName: String?

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
            HotkeyManager.shared.beginHotkeyCapture()
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
        guard recorderState.isActive else { return }
        recorderState.isActive = false
        recorderState.pendingRecord?.cancel()
        recorderState.pendingRecord = nil
        stopListening()
        HotkeyManager.shared.endHotkeyCapture()
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
