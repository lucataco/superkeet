import SwiftUI
import AVFoundation
import AppKit

/// Multi-step onboarding wizard shown on first launch.
/// Walks through permissions, engine verification, and hotkey setup.
struct OnboardingView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var hotkeyManager = HotkeyManager.shared
    @State private var currentStep: Int = 0
    @State private var readiness = AppReadiness.current()

    /// Called when the user completes onboarding
    var onComplete: () -> Void

    private let totalSteps = 4

    var body: some View {
        VStack(spacing: 0) {
            // Step content
            Group {
                switch currentStep {
                case 0: welcomeStep
                case 1: permissionsStep
                case 2: engineStep
                case 3: shortcutsStep
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
                        refreshReadiness()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Start Using Superkeet") {
                        settings.hasCompletedOnboarding = true
                        onComplete()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
        }
    }

    // MARK: - Step 1: Welcome

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

    // MARK: - Step 2: Permissions

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Permissions")
                    .font(.title)
                    .fontWeight(.bold)
                Text("Superkeet needs a couple of permissions to work. Grant them now or later in System Settings.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            VStack(spacing: 16) {
                permissionRow(
                    title: "Microphone Access",
                    detail: microphoneStatusText,
                    isGranted: readiness.diagnostics.microphoneStatus == .authorized,
                    buttonTitle: "Grant Access"
                ) {
                    AVCaptureDevice.requestAccess(for: .audio) { _ in
                        DispatchQueue.main.async { refreshReadiness() }
                    }
                }

                permissionRow(
                    title: "Accessibility",
                    detail: "Needed for global hotkeys and auto-paste. You can skip this for now.",
                    isGranted: hotkeyManager.accessibilityGranted,
                    buttonTitle: "Open Settings"
                ) {
                    hotkeyManager.checkAccessibility()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { refreshReadiness() }
                }
            }

            Spacer()

            Button("Refresh Status") {
                refreshReadiness()
            }
            .buttonStyle(.bordered)
        }
        .padding(24)
    }

    private var microphoneStatusText: String {
        switch readiness.diagnostics.microphoneStatus {
        case .authorized: return "Microphone access granted."
        case .denied: return "Denied. Open System Settings > Privacy > Microphone to re-enable."
        case .restricted: return "Restricted by the system."
        case .notDetermined: return "Not yet requested. Click Grant Access."
        @unknown default: return "Unknown status."
        }
    }

    private func permissionRow(
        title: String,
        detail: String,
        isGranted: Bool,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isGranted ? .green : .secondary)
                .font(.system(size: 20))
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if !isGranted {
                Button(buttonTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(10)
    }

    // MARK: - Step 3: Engine

    private var engineStep: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Speech Engine")
                    .font(.title)
                    .fontWeight(.bold)
                Text("Superkeet uses a bundled Parakeet engine for local speech recognition. Make sure the embedded binary is present.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            VStack(spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: readiness.diagnostics.engineBinaryExists ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(readiness.diagnostics.engineBinaryExists ? .green : .red)
                        .font(.system(size: 20))
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(readiness.diagnostics.engineBinaryExists ? "Engine Found" : "Engine Not Found")
                            .font(.system(size: 14, weight: .medium))
                        Text("Looking at: \(settings.parakeetBinaryPath)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)

                        if !readiness.diagnostics.engineBinaryExists {
                            Text("The embedded engine is missing. Reinstall Superkeet with ./install.sh to restore the signed app bundle.")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.orange)
                                .padding(.top, 4)
                        }
                    }

                    Spacer()
                }
                .padding(14)
                .background(Color.primary.opacity(0.04))
                .cornerRadius(10)
            }

            Button("Refresh") {
                refreshReadiness()
            }
            .buttonStyle(.bordered)

            Spacer()
        }
        .padding(24)
    }

    // MARK: - Step 4: Shortcuts

    private var shortcutsStep: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Keyboard Shortcuts")
                    .font(.title)
                    .fontWeight(.bold)
                Text("These are the default shortcuts. You can change them anytime in Settings.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            VStack(spacing: 16) {
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

            VStack(alignment: .leading, spacing: 8) {
                Text("You're all set!")
                    .font(.headline)
                Text("Click \"Start Using Superkeet\" to launch the speech engine and begin using voice-to-text.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 8)

            Spacer()
        }
        .padding(24)
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

    // MARK: - Helpers

    private func refreshReadiness() {
        readiness = AppReadiness.current()
    }
}
