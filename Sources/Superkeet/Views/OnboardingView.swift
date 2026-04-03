import SwiftUI
import AVFoundation
import AppKit
import Combine

/// Multi-step onboarding wizard shown on first launch.
/// Walks through permissions, engine verification, and hotkey setup.
struct OnboardingView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var hotkeyManager = HotkeyManager.shared
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

    private let totalSteps = 4

    var body: some View {
        VStack(spacing: 0) {
            // Step content
            Group {
                switch currentStep {
                case 0: welcomeStep
                case 1: microphoneStep
                case 2: accessibilityStep
                case 3: readyStep
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
                    Button("Start Using Superkeet") {
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

    // MARK: - Step 2: Accessibility

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

    // MARK: - Step 3: Ready

    private var readyStep: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("You're All Set!")
                        .font(.title)
                        .fontWeight(.bold)
                    Text("Here are your default keyboard shortcuts. You can change them anytime in Settings.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
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
                }
                .padding(14)
                .background(Color.primary.opacity(0.03))
                .cornerRadius(10)
            }

            Spacer()

            Text("Click \"Start Using Superkeet\" to launch the speech engine and begin.")
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
