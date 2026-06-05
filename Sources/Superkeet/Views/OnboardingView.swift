import SwiftUI
import AVFoundation
import AppKit
import Combine

/// Multi-step onboarding wizard shown on first launch.
/// Walks through permissions, engine verification, and hotkey setup.
struct OnboardingView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var hotkeyManager = HotkeyManager.shared
    @ObservedObject var modelProvisioning = ModelProvisioning.shared
    @State private var currentStep: Int = 0
    @State private var readiness = AppReadiness.current()

    // Accessibility polling
    @State private var accessibilityPollingTimer: Timer?
    @State private var accessibilityGranted: Bool = false
    @State private var didTriggerAccessibilityPrompt: Bool = false
    @State private var pendingAccessibilitySettingsOpen: DispatchWorkItem?

    // Microphone state
    @State private var microphoneGranted: Bool = false
    @State private var microphoneRequested: Bool = false

    /// Called when the user completes onboarding
    var onComplete: () -> Void

    private let totalSteps = 5

    /// Step index for the accessibility step (used to drive permission polling).
    private let accessibilityStepIndex = 3

    private enum OnboardingOutputMode {
        case clipboard
        case autoPaste
    }

    var body: some View {
        VStack(spacing: 0) {
            // Step content
            Group {
                switch currentStep {
                case 0: welcomeStep
                case 1: microphoneStep
                case 2: modelStep
                case 3: accessibilityStep
                case 4: readyStep
                default: welcomeStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Navigation bar
            HStack {
                // Step indicator
                HStack(spacing: 6) {
                    ForEach(0..<totalSteps, id: \.self) { step in
                        Circle()
                            .fill(step == currentStep ? Color.accentColor : Color.primary.opacity(0.15))
                            .frame(width: 8, height: 8)
                    }
                }

                Spacer()

                if currentStep > 0 {
                    Button("Back") {
                        withAnimation { currentStep -= 1 }
                    }
                    .buttonStyle(.bordered)
                }

                if currentStep < totalSteps - 1 {
                    Button("Continue") {
                        withAnimation { currentStep += 1 }
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
            // Seed initial state
            microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            accessibilityGranted = hotkeyManager.checkAccessibilitySilently()
        }
        .onChange(of: currentStep) {
            if currentStep == 2 {
                // Kick off the model download as soon as the user reaches it, so
                // it runs in the background while they finish the rest of setup.
                modelProvisioning.startDownloadIfNeeded()
            }
            if currentStep == accessibilityStepIndex {
                startAccessibilityPolling()
            } else {
                stopAccessibilityPolling()
            }
        }
        .onDisappear {
            stopAccessibilityPolling()
            cancelPendingAccessibilitySettingsOpen()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Refresh everything when user switches back to the app
            readiness = AppReadiness.current()
            microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            accessibilityGranted = hotkeyManager.checkAccessibilitySilently()
            syncAccessibilityState(accessibilityGranted)
        }
        .onChange(of: modelProvisioning.state) {
            // Keep the readiness summary in sync as the model download completes.
            readiness = AppReadiness.current()
        }
    }

    // MARK: - Step 0: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

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

    // MARK: - Step 1: Microphone

    private var microphoneStep: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                // Icon
                ZStack {
                    Circle()
                        .fill(microphoneGranted ? Color.green.opacity(0.12) : Color.blue.opacity(0.12))
                        .frame(width: 80, height: 80)
                    Image(systemName: microphoneGranted ? "checkmark.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 44))
                        .foregroundColor(microphoneGranted ? .green : .blue)
                }

                VStack(spacing: 8) {
                    Text("Microphone Access")
                        .font(.title)
                        .fontWeight(.bold)

                    Text("Superkeet needs your microphone to hear\nand transcribe your voice.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }

                if microphoneGranted {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Microphone access granted")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.green)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.green.opacity(0.08))
                    .cornerRadius(10)
                } else if microphoneRequested && AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
                    // Permission was denied — guide user to System Settings
                    VStack(spacing: 12) {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("Microphone access was denied")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.primary)
                        }

                        Text("You can enable it in System Settings:")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Button {
                            openMicrophoneSettings()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "gear")
                                Text("Open Microphone Settings")
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(16)
                    .background(Color.orange.opacity(0.06))
                    .cornerRadius(10)
                } else {
                    Button {
                        requestMicrophoneAccess()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "mic.fill")
                            Text("Grant Microphone Access")
                        }
                        .frame(minWidth: 200)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }

            Spacer()

            // Subtle note at bottom
            Text("Audio never leaves your Mac. All processing happens locally.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.bottom, 8)
        }
        .padding(24)
    }

    // MARK: - Step 2: Speech Model

    private var modelStep: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .fill(modelStepIconBackground)
                        .frame(width: 80, height: 80)
                    Image(systemName: modelStepIconName)
                        .font(.system(size: 44))
                        .foregroundColor(modelStepIconColor)
                }

                VStack(spacing: 8) {
                    Text(modelStepTitle)
                        .font(.title)
                        .fontWeight(.bold)

                    Text(modelStepSubtitle)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }

                modelStepStatusContent
                    .frame(maxWidth: 340)
            }

            Spacer()

            Text("The model runs entirely on your Mac. This download happens only once.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.bottom, 8)
        }
        .padding(24)
        .onAppear {
            modelProvisioning.startDownloadIfNeeded()
        }
    }

    @ViewBuilder
    private var modelStepStatusContent: some View {
        switch modelProvisioning.state {
        case .installed:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Speech model ready")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.green)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Color.green.opacity(0.08))
            .cornerRadius(10)

        case .downloading(let progress):
            VStack(spacing: 12) {
                ProgressView(value: progress.overallFraction)
                    .progressViewStyle(.linear)

                HStack {
                    Text("Downloading \(progress.currentFileName)")
                    Spacer()
                    Text("\(Int((progress.overallFraction * 100).rounded()))%")
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundColor(.secondary)

                Text(modelStepDetailLine(progress))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .failed(let message):
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    modelProvisioning.startDownloadIfNeeded()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                        Text("Try Again")
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(14)
            .background(Color.orange.opacity(0.06))
            .cornerRadius(10)

        case .verifying:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Verifying download…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

        case .checking, .notInstalled, .unknown:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Preparing download…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func modelStepDetailLine(_ progress: ModelDownloadProgress) -> String {
        let filePosition = "file \(min(progress.fileIndex + 1, progress.totalFiles)) of \(progress.totalFiles)"
        guard progress.totalBytes > 0 else { return filePosition }
        let downloaded = Self.byteFormatter.string(fromByteCount: progress.downloadedBytes)
        let total = Self.byteFormatter.string(fromByteCount: progress.totalBytes)
        return "\(downloaded) of \(total) · \(filePosition)"
    }

    private var modelStepTitle: String {
        switch modelProvisioning.state {
        case .installed: return "Speech Model Ready"
        case .failed: return "Download Needs Attention"
        default: return "Setting Up the Speech Engine"
        }
    }

    private var modelStepSubtitle: String {
        switch modelProvisioning.state {
        case .installed:
            return "Everything you need to transcribe now lives on your Mac."
        case .failed:
            return "Superkeet needs the on-device speech model before it can transcribe. You can retry now or later from Settings."
        default:
            return "Downloading the local speech model (about 670 MB).\nThis runs once — then transcription is fully offline."
        }
    }

    private var modelStepIconName: String {
        switch modelProvisioning.state {
        case .installed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        default: return "arrow.down.circle.fill"
        }
    }

    private var modelStepIconColor: Color {
        switch modelProvisioning.state {
        case .installed: return .green
        case .failed: return .orange
        default: return .blue
        }
    }

    private var modelStepIconBackground: Color {
        switch modelProvisioning.state {
        case .installed: return Color.green.opacity(0.12)
        case .failed: return Color.orange.opacity(0.12)
        default: return Color.blue.opacity(0.12)
        }
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()

    // MARK: - Step 3: Accessibility

    private var accessibilityStep: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                // Icon
                ZStack {
                    Circle()
                        .fill(accessibilityGranted ? Color.green.opacity(0.12) : Color.blue.opacity(0.12))
                        .frame(width: 80, height: 80)
                    Image(systemName: accessibilityGranted ? "checkmark.circle.fill" : "lock.shield.fill")
                        .font(.system(size: 44))
                        .foregroundColor(accessibilityGranted ? .green : .blue)
                }

                VStack(spacing: 8) {
                    Text(accessibilityGranted ? "Accessibility Enabled" : "Authorize Superkeet")
                        .font(.title)
                        .fontWeight(.bold)

                    Text(accessibilityGranted
                        ? "Superkeet can now use global keyboard shortcuts\nand automatically paste transcribed text."
                        : "Superkeet needs Accessibility permission to listen\nfor keyboard shortcuts and auto-paste text.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }

                if accessibilityGranted {
                    // Granted state
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Accessibility access granted")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.green)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.green.opacity(0.08))
                    .cornerRadius(10)
                } else {
                    // Instructions + Open Settings button
                    VStack(spacing: 16) {
                        // Numbered instructions
                        VStack(alignment: .leading, spacing: 10) {
                            instructionRow(number: "1", text: "Click \"Open System Settings\" below")
                            instructionRow(number: "2", text: "Find **Superkeet** in the list")
                            instructionRow(number: "3", text: "Toggle the switch to enable it")
                        }
                        .padding(.horizontal, 8)

                        Button {
                            openAccessibilitySettings()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "gear")
                                Text("Open System Settings")
                            }
                            .frame(minWidth: 200)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        // Polling indicator
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Waiting for permission...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            Spacer()

            // Skip option
            if !accessibilityGranted {
                VStack(spacing: 4) {
                    Text("You can skip this step, but global hotkeys and auto-paste won't work.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("You can grant access later from the menu bar icon.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.bottom, 8)
            }
        }
        .padding(24)
        .onAppear {
            triggerAccessibilityPromptIfNeeded()
        }
    }

    private func instructionRow(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor)
                .clipShape(Circle())

            Text(LocalizedStringKey(text))
                .font(.system(size: 13))
                .foregroundColor(.primary)
        }
    }

    // MARK: - Step 4: Ready

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

                    shortcutRow(
                        title: "Cancel Recording",
                        description: "Press Escape while recording to cancel",
                        displayName: "Esc"
                    )
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("After each transcription")
                        .font(.headline)

                    Text("Choose the default output flow for first run. You can still fine-tune clipboard, auto-paste, and history later in Settings.")
                        .font(.caption)
                        .foregroundColor(.secondary)

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

                    if selectedOutputMode == .autoPaste && !accessibilityGranted {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundColor(.orange)
                            Text("Auto-paste is selected, but Accessibility access is still off. Superkeet will still copy transcripts to the clipboard, but automatic paste will not work until you grant access.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(10)
                        .background(Color.orange.opacity(0.06))
                        .cornerRadius(10)
                    }
                }

                // Engine warning (only shown if engine binary is missing)
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

                // Model still downloading in the background
                if modelProvisioning.state.isBusy {
                    HStack(alignment: .center, spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Finishing speech model download")
                                .font(.system(size: 13, weight: .medium))
                            Text("You can start using Superkeet as soon as this completes.")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(12)
                    .background(Color.blue.opacity(0.06))
                    .cornerRadius(10)
                }

                // Permission summary
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
                        icon: "waveform",
                        title: "Speech Engine",
                        granted: readiness.diagnostics.engineBinaryExists
                    )
                    permissionSummaryRow(
                        icon: "arrow.down.circle",
                        title: "Speech Model",
                        granted: modelProvisioning.state.isInstalled
                    )
                    permissionSummaryRow(
                        icon: "mic.badge.plus",
                        title: "Input Device",
                        granted: inputDeviceReady
                    )
                    permissionSummaryRow(
                        icon: "folder.badge.gearshape",
                        title: "Runtime Directory",
                        granted: readiness.diagnostics.runtimeDirectoryWritable
                    )
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

    // MARK: - Actions

    private func requestMicrophoneAccess() {
        microphoneRequested = true
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                microphoneGranted = granted
                readiness = AppReadiness.current()
            }
        }
    }

    private func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func triggerAccessibilityPromptIfNeeded() {
        guard !didTriggerAccessibilityPrompt && !accessibilityGranted else { return }
        didTriggerAccessibilityPrompt = true
        cancelPendingAccessibilitySettingsOpen()

        // This call adds "Superkeet" to the Accessibility list in System Settings
        // and shows the macOS system prompt asking the user to open System Settings.
        hotkeyManager.checkAccessibility()

        // After a short delay, open System Settings directly to the Accessibility pane
        // so the user just needs to find Superkeet and toggle the switch.
        let workItem = DispatchWorkItem {
            openAccessibilitySettings()
        }
        pendingAccessibilitySettingsOpen = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
    }

    private func cancelPendingAccessibilitySettingsOpen() {
        pendingAccessibilitySettingsOpen?.cancel()
        pendingAccessibilitySettingsOpen = nil
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Accessibility Polling

    private func startAccessibilityPolling() {
        stopAccessibilityPolling()
        accessibilityPollingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            let granted = hotkeyManager.checkAccessibilitySilently()
            if granted != accessibilityGranted {
                accessibilityGranted = granted
                syncAccessibilityState(granted)
            }
        }
    }

    private func stopAccessibilityPolling() {
        accessibilityPollingTimer?.invalidate()
        accessibilityPollingTimer = nil
    }

    private func syncAccessibilityState(_ granted: Bool) {
        hotkeyManager.accessibilityGranted = granted
        guard granted else { return }
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
