import SwiftUI
import AVFoundation
import AppKit

struct OnboardingView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var hotkeyManager = HotkeyManager.shared
    @ObservedObject var modelProvisioning = ModelProvisioning.shared
    @State private var currentStep: OnboardingStep = .welcome
    @State private var readiness = AppReadinessReport.placeholder

    @State private var accessibilityPollingTimer: Timer?
    @State private var accessibilityGranted: Bool = false
    @State private var didTriggerAccessibilityPrompt: Bool = false

    @State private var microphoneGranted: Bool = false

    var onComplete: () -> Void

    /// Five screens on macOS 26, four elsewhere. The model download runs in the background from
    /// the first screen and is shown as a footer progress bar rather than a step. The Actions step
    /// only appears on systems that can run the on-device planner.
    private enum OnboardingStep: Int, CaseIterable {
        case welcome
        case permissions
        case output
        case actions
        case ready
    }

    private var visibleSteps: [OnboardingStep] {
        OnboardingStep.allCases.filter { $0 != .actions || AppleIntelligenceAvailability.osSupportsActionsMode }
    }

    private func step(after step: OnboardingStep) -> OnboardingStep? {
        guard let index = visibleSteps.firstIndex(of: step), index + 1 < visibleSteps.count else { return nil }
        return visibleSteps[index + 1]
    }

    private func step(before step: OnboardingStep) -> OnboardingStep? {
        guard let index = visibleSteps.firstIndex(of: step), index > 0 else { return nil }
        return visibleSteps[index - 1]
    }

    private enum OnboardingOutputMode {
        case clipboard
        case autoPaste
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch currentStep {
                case .welcome: welcomeStep
                case .permissions: permissionsStep
                case .output: outputStep
                case .actions: actionsStep
                case .ready: readyStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if currentStep != .welcome, !modelProvisioning.state.isInstalled {
                modelDownloadBar
            }

            Divider()

            HStack {
                HStack(spacing: 6) {
                    ForEach(visibleSteps, id: \.self) { step in
                        Circle()
                            .fill(step == currentStep ? Color.accentColor : Color.primary.opacity(0.15))
                            .frame(width: 8, height: 8)
                    }
                }

                Spacer()

                if step(before: currentStep) != nil {
                    Button("Back") {
                        withAnimation { goToPreviousStep() }
                    }
                    .buttonStyle(.bordered)
                }

                if step(after: currentStep) != nil {
                    Button("Continue") {
                        withAnimation { goToNextStep() }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button(completionButtonTitle) {
                        onComplete()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
        }
        .onAppear {
            readiness = AppReadiness.current()
            microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            accessibilityGranted = hotkeyManager.checkAccessibilitySilently()
            // Start the ~670 MB model download immediately so it is usually finished by the time
            // the user reaches the model step, instead of making them sit and watch it.
            modelProvisioning.startDownloadIfNeeded()
        }
        .onChange(of: currentStep) {
            if currentStep == .permissions {
                requestPermissionsInSequence()
                startAccessibilityPolling()
            } else {
                stopAccessibilityPolling()
            }
        }
        .onDisappear {
            stopAccessibilityPolling()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            readiness = AppReadiness.current()
            microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            accessibilityGranted = hotkeyManager.checkAccessibilitySilently()
            syncAccessibilityState(accessibilityGranted)
        }
        .onChange(of: modelProvisioning.state.phase) {
            // Re-probe only on state transitions, not on every download progress tick.
            readiness = AppReadiness.current()
        }
        .onChange(of: settings.actionsEnabled) { _, enabled in
            guard enabled else { return }
            Task {
                await SpeculativeLaunchCoordinator.shared.prepare()
                await MCPClientManager.shared.connectEnabledServersIfNeeded()
            }
        }
    }

    private var welcomeStep: some View {
        VStack(spacing: 24) {
            Spacer()

            AppIconView()

            VStack(spacing: 8) {
                Text("Welcome to Superkeet")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Local voice-to-text powered by Parakeet.\nFast, private, and fully offline.")
                    .font(.title3)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 6) {
                featureRow(icon: "mic.fill", text: "Press a hotkey to start recording")
                featureRow(icon: "text.cursor", text: "Your speech is transcribed locally")
                featureRow(icon: "clipboard", text: "Text is copied or pasted automatically")
                featureRow(icon: "lock.shield.fill", text: "Nothing leaves your Mac")
            }
            .padding(.horizontal, 40)

            Spacer()

            Text("Superkeet is downloading its on-device speech model (about 670 MB) in the background. After that it runs completely offline.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
        }
        .padding(24)
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
                .frame(width: 20)
            Text(text)
                .font(.body)
                .foregroundColor(.primary)
            Spacer()
        }
    }

    private func statusPill(text: String, tint: Color, icon: String = "checkmark.circle.fill") -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(tint)
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(tint)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(tint.opacity(0.08))
        .cornerRadius(10)
    }

    private func goToNextStep() {
        guard let next = step(after: currentStep) else { return }
        currentStep = next
    }

    private func goToPreviousStep() {
        guard let previous = step(before: currentStep) else { return }
        currentStep = previous
    }

    private var permissionsStep: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Text("Two Permissions")
                        .font(.title)
                        .fontWeight(.bold)

                    Text("Microphone so Superkeet can hear you. Accessibility so your\nshortcuts work in every app and pasting can be automatic.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 12) {
                    microphonePermissionCard
                    accessibilityPermissionCard
                }
                .frame(maxWidth: 440)
            }

            Spacer()

            Text("Audio never leaves your Mac. Accessibility is only used to listen for your shortcuts and send ⌘V.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
        }
        .padding(24)
    }

    private var microphonePermissionCard: some View {
        permissionCard(
            icon: "mic.fill",
            title: "Microphone",
            granted: microphoneGranted,
            grantedText: "Access granted"
        ) {
            if microphoneAccessDenied {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Access was denied. Turn it on for Superkeet in System Settings.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button("Open Microphone Settings") { openMicrophoneSettings() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            } else {
                Button("Grant Microphone Access") { requestMicrophoneAccess() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }

    private var accessibilityPermissionCard: some View {
        permissionCard(
            icon: "lock.shield.fill",
            title: "Accessibility",
            granted: accessibilityGranted,
            grantedText: "Shortcuts and automatic paste enabled"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text("In System Settings, find **Superkeet** in the Accessibility list and turn it on. This screen updates automatically.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack(spacing: 10) {
                    Button("Open System Settings") { openAccessibilitySettings() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Waiting…")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Text("You can skip this, but shortcuts won't work until it's granted. Recording from the menu bar still works.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func permissionCard<Pending: View>(
        icon: String,
        title: String,
        granted: Bool,
        grantedText: String,
        @ViewBuilder pending: () -> Pending
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(granted ? Color.green.opacity(0.12) : Color.blue.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: granted ? "checkmark" : icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(granted ? .green : .blue)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                if granted {
                    Text(grantedText)
                        .font(.caption)
                        .foregroundColor(.green)
                } else {
                    pending()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(10)
    }

    /// Compact download status shown beneath every step after Welcome until the model is in place.
    @ViewBuilder
    private var modelDownloadBar: some View {
        HStack(spacing: 10) {
            switch modelProvisioning.state {
            case .downloading(let progress):
                ProgressView(value: progress.overallFraction)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 220)
                Text("Downloading speech model · \(Int((progress.overallFraction * 100).rounded()))% · \(modelStepDetailLine(progress))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundColor(.primary)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Button("Try Again") { modelProvisioning.startDownloadIfNeeded() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            case .verifying:
                ProgressView().controlSize(.small)
                Text("Verifying speech model…")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
            case .checking, .notInstalled, .unknown:
                ProgressView().controlSize(.small)
                Text("Preparing speech model download (about 670 MB, one time)…")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
            case .installed:
                EmptyView()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.03))
    }

    private func modelStepDetailLine(_ progress: ModelDownloadProgress) -> String {
        let filePosition = "file \(min(progress.fileIndex + 1, progress.totalFiles)) of \(progress.totalFiles)"
        guard progress.totalBytes > 0 else { return filePosition }
        let downloaded = Self.byteFormatter.string(fromByteCount: progress.downloadedBytes)
        let total = Self.byteFormatter.string(fromByteCount: progress.totalBytes)
        return "\(downloaded) of \(total) · \(filePosition)"
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()

    private var outputStep: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.12))
                        .frame(width: 80, height: 80)
                    Image(systemName: "doc.on.clipboard.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.blue)
                }

                VStack(spacing: 8) {
                    Text("After Each Transcription")
                        .font(.title)
                        .fontWeight(.bold)

                    Text("Choose what Superkeet does with your transcribed text.\nYou can change this anytime in Settings.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 12) {
                    OnboardingOutputModeOption(
                        title: "Copy to Clipboard",
                        description: "Recommended. Safer default that lets you choose where to paste.",
                        icon: "clipboard",
                        isSelected: selectedOutputMode == .clipboard,
                        action: { selectOutputMode(.clipboard) }
                    )

                    OnboardingOutputModeOption(
                        title: "Paste Automatically",
                        description: "Fastest flow. Pastes into the last active app and keeps the transcript on your clipboard.",
                        icon: "doc.on.clipboard",
                        isSelected: selectedOutputMode == .autoPaste,
                        action: { selectOutputMode(.autoPaste) }
                    )
                }
                .frame(maxWidth: 440)

                if selectedOutputMode == .autoPaste && !accessibilityGranted {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                        Text("Auto-paste needs Accessibility access, which isn't enabled yet. Superkeet will still copy transcripts to the clipboard until you turn it on.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.06))
                    .cornerRadius(10)
                    .frame(maxWidth: 440)
                }
            }

            Spacer()

            Text("Either way, your transcript is always copied to the clipboard.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.bottom, 8)
        }
        .padding(24)
    }

    private var actionsStep: some View {
        let availability = AppleIntelligenceAvailability.current
        return VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(Color.purple.opacity(0.12))
                        .frame(width: 80, height: 80)
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 40))
                        .foregroundColor(.purple)
                }

                VStack(spacing: 8) {
                    Text("Do Things by Voice")
                        .font(.title)
                        .fontWeight(.bold)

                    Text("Say “open Chrome and search for Morgan Freeman” and Superkeet opens Chrome while you are still talking, then runs the search. Optional, and separate from dictation.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                }

                Toggle(isOn: $settings.actionsEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable Actions Mode")
                            .font(.system(size: 13, weight: .medium))
                        Text(availability.isAvailable
                             ? "Apps and web pages open instantly. Broader tasks use Apple Intelligence on this Mac."
                             : availability.detail)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .frame(maxWidth: 460)

                if settings.actionsEnabled {
                    HStack(spacing: 12) {
                        ForEach(ActionApprovalPolicy.allCases) { policy in
                            OnboardingOutputModeOption(
                                title: policy.title,
                                description: policy.subtitle,
                                icon: approvalPolicyIcon(policy),
                                isSelected: settings.actionApprovalPolicy == policy,
                                action: { settings.actionApprovalPolicy = policy }
                            )
                        }
                    }
                    .frame(maxWidth: 560)

                    VStack(spacing: 8) {
                        shortcutRow(
                            title: "Run an Action",
                            description: "Press once to start speaking, press again to run",
                            displayName: settings.commandHotkeyDisplayName
                        )
                        shortcutRow(
                            title: "Hold to Run an Action",
                            description: "Hold while speaking, release to run",
                            displayName: settings.commandPTTHotkeyDisplayName
                        )
                    }
                    .frame(maxWidth: 560)
                }
            }

            Spacer()

            Text(settings.actionsEnabled
                 ? "Apps named in a command open before you finish speaking. Browser and app-control MCP servers are optional and live in Settings ▸ Actions."
                 : "You can turn this on later in Settings ▸ Actions.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 8)
        }
        .padding(24)
    }

    private func approvalPolicyIcon(_ policy: ActionApprovalPolicy) -> String {
        switch policy {
        case .alwaysAsk: return "hand.raised"
        case .readOnlyAuto: return "shield.lefthalf.filled"
        case .autoApprove: return "bolt.fill"
        }
    }

    private var readyStep: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(readyStepTitle)
                        .font(.title)
                        .fontWeight(.bold)
                    Text(readyStepSubtitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                if !isReadyForSelectedConfiguration {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(blockingIssueTitle, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.orange)

                        ForEach(blockingIssueDetails, id: \.self) { detail in
                            Text(detail)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(12)
                    .background(Color.orange.opacity(0.08))
                    .cornerRadius(10)
                }

                VStack(spacing: 12) {
                    shortcutRow(
                        title: "Toggle Recording",
                        description: "Press once to start, press again to stop",
                        displayName: settings.toggleHotkeyDisplayName
                    )

                    shortcutRow(
                        title: "Push to Talk",
                        description: "Hold to record, release to stop",
                        displayName: settings.pttHotkeyDisplayName
                    )

                    if settings.actionsEnabled {
                        shortcutRow(
                            title: "Run an Action",
                            description: "Press once to start speaking a task, press again to run it",
                            displayName: settings.commandHotkeyDisplayName
                        )

                        shortcutRow(
                            title: "Hold to Run an Action",
                            description: "Hold while speaking a task, release to run it",
                            displayName: settings.commandPTTHotkeyDisplayName
                        )
                    }

                    shortcutRow(
                        title: "Cancel Recording",
                        description: "Press Escape while recording to cancel",
                        displayName: "Esc"
                    )
                }

                if !readiness.diagnostics.engineBinaryExists {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.system(size: 16))

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Speech engine not found")
                                .font(.system(size: 13, weight: .medium))
                            Text("Reinstall Superkeet to restore the engine binary. Voice transcription won't work until this is resolved.")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(12)
                    .background(Color.orange.opacity(0.08))
                    .cornerRadius(10)
                }

                VStack(spacing: 8) {
                    permissionSummaryRow(
                        icon: "mic.fill",
                        title: "Microphone",
                        granted: microphoneGranted
                    )
                    permissionSummaryRow(
                        icon: "lock.shield.fill",
                        title: "Accessibility",
                        granted: accessibilityGranted
                    )
                    permissionSummaryRow(
                        icon: "arrow.down.circle",
                        title: "Speech Model",
                        granted: modelProvisioning.state.isInstalled
                    )

                    if !readiness.diagnostics.engineBinaryExists {
                        permissionSummaryRow(
                            icon: "waveform",
                            title: "Speech Engine",
                            granted: false
                        )
                    }
                    if !inputDeviceReady {
                        permissionSummaryRow(
                            icon: "mic.badge.plus",
                            title: "Input Device",
                            granted: false
                        )
                    }
                    if !readiness.diagnostics.runtimeDirectoryWritable {
                        permissionSummaryRow(
                            icon: "folder.badge.gearshape",
                            title: "Runtime Directory",
                            granted: false
                        )
                    }
                }
                .padding(14)
                .background(Color.primary.opacity(0.03))
                .cornerRadius(10)
            }

            Spacer()

            Text(readyStepFooter)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.bottom, 8)
        }
        .padding(24)
        .onAppear {
            readiness = AppReadiness.current()
        }
    }

    private func shortcutRow(title: String, description: String, displayName: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text(displayName)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.08))
                .cornerRadius(8)
        }
        .padding(14)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(10)
    }

    private func permissionSummaryRow(icon: String, title: String, granted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(.secondary)
                .frame(width: 16)
            Text(title)
                .font(.system(size: 13))
            Spacer()
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundColor(granted ? .green : .orange)
                .font(.system(size: 14))
        }
    }

    private var completionButtonTitle: String {
        isReadyForSelectedConfiguration ? "Start Using Superkeet" : "Continue to Superkeet"
    }

    private var selectedOutputMode: OnboardingOutputMode {
        settings.autoPasteEnabled ? .autoPaste : .clipboard
    }

    private var isReadyForSelectedConfiguration: Bool {
        readiness.isReadyForSelectedConfiguration(autoPasteEnabled: settings.autoPasteEnabled)
    }

    private var readyStepTitle: String {
        isReadyForSelectedConfiguration ? "You're All Set!" : "Setup Still Needs Attention"
    }

    private var readyStepSubtitle: String {
        if isReadyForSelectedConfiguration {
            return "Here are your default keyboard shortcuts. You can change them anytime in Settings."
        }
        if selectedOutputMode == .autoPaste && readiness.issues.contains(.accessibility) {
            return "Recording is nearly ready, but the selected auto-paste flow still needs Accessibility access before Superkeet can finish setup for your chosen output mode."
        }
        return "Superkeet can finish onboarding now, but recording will stay unavailable until the blocking setup items below are resolved in Settings."
    }

    private var readyStepFooter: String {
        if isReadyForSelectedConfiguration {
            return "Click \"Start Using Superkeet\" to launch the speech engine and begin."
        }
        if selectedOutputMode == .autoPaste && readiness.issues.contains(.accessibility) {
            return "Continue to Superkeet to access the menu bar app. Setup will remain unverified until Accessibility is granted for automatic paste."
        }
        return "Continue to Superkeet to access the menu bar app. Setup will remain unverified until recording is ready."
    }

    private var inputDeviceReady: Bool {
        readiness.diagnostics.hasInputDevice && readiness.diagnostics.configuredInputDeviceFound
    }

    private var blockingIssueDetails: [String] {
        readiness.issues
            .filter { issue in
                if issue == .accessibility {
                    return selectedOutputMode == .autoPaste
                }
                return true
            }
            .map(\.detail)
    }

    private var blockingIssueTitle: String {
        if selectedOutputMode == .autoPaste && readiness.issues == [.accessibility] {
            return "Automatic paste is still blocked"
        }
        return "Setup still needs attention"
    }

    private func selectOutputMode(_ mode: OnboardingOutputMode) {
        settings.clipboardCopyEnabled = true
        settings.autoPasteEnabled = mode == .autoPaste
    }

    private var microphoneAccessDenied: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return status == .denied || status == .restricted
    }

    private func requestMicrophoneAccess() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                microphoneGranted = granted
                readiness = AppReadiness.current()
            }
        }
    }

    /// Show the system prompts one at a time: microphone first (if never asked), then Accessibility.
    private func requestPermissionsInSequence() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    microphoneGranted = granted
                    readiness = AppReadiness.current()
                    triggerAccessibilityPromptIfNeeded()
                }
            }
        } else {
            triggerAccessibilityPromptIfNeeded()
        }
    }

    private func openMicrophoneSettings() {
        SystemSettingsLinks.openMicrophone()
    }

    private func triggerAccessibilityPromptIfNeeded() {
        guard !didTriggerAccessibilityPrompt && !accessibilityGranted else { return }
        didTriggerAccessibilityPrompt = true

        hotkeyManager.checkAccessibility()
    }

    private func openAccessibilitySettings() {
        SystemSettingsLinks.openAccessibility()
    }

    private func startAccessibilityPolling() {
        stopAccessibilityPolling()
        accessibilityPollingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                let granted = hotkeyManager.checkAccessibilitySilently()
                if granted != accessibilityGranted {
                    accessibilityGranted = granted
                    syncAccessibilityState(granted)
                }
            }
        }
    }

    private func stopAccessibilityPolling() {
        accessibilityPollingTimer?.invalidate()
        accessibilityPollingTimer = nil
    }

    private func syncAccessibilityState(_ granted: Bool) {
        hotkeyManager.accessibilityGranted = granted
        guard granted, settings.hasCompletedOnboarding else { return }
        hotkeyManager.startListening()
        if !hotkeyManager.isListening {
            hotkeyManager.startRetryTimer()
        }
    }
}

private struct OnboardingOutputModeOption: View {
    let title: String
    let description: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 18))
                        .foregroundColor(isSelected ? .accentColor : .secondary)

                    Spacer()

                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(isSelected ? .accentColor : .secondary.opacity(0.5))
                }

                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)

                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
            .padding(14)
            .background(isSelected ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.08), lineWidth: 1.5)
            )
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }
}
