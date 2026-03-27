import SwiftUI

/// Output settings: visualization style, auto-paste, clipboard behavior
struct OutputTabView: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Output")
                    .font(.title)
                    .fontWeight(.bold)

                // Recording Visualization
                VStack(alignment: .leading, spacing: 12) {
                    Label("Recording Visualization", systemImage: "waveform")
                        .font(.headline)

                    Text("Choose how the recording overlay appears while you're speaking")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack(spacing: 12) {
                        VisualizationOption(
                            title: "Classic",
                            description: "Expanded overlay with bar equalizer",
                            icon: "waveform.path",
                            isSelected: settings.recordingOverlayStyle == "classic"
                        ) {
                            settings.recordingOverlayStyle = "classic"
                        }

                        VisualizationOption(
                            title: "Mini",
                            description: "Compact pill with dot equalizer",
                            icon: "ellipsis",
                            isSelected: settings.recordingOverlayStyle == "mini"
                        ) {
                            settings.recordingOverlayStyle = "mini"
                        }

                        VisualizationOption(
                            title: "None",
                            description: "No overlay shown",
                            icon: "eye.slash",
                            isSelected: settings.recordingOverlayStyle == "none"
                        ) {
                            settings.recordingOverlayStyle = "none"
                        }
                    }
                }

                Divider()

                // Auto-paste
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $settings.autoPasteEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Auto-paste", systemImage: "doc.on.clipboard")
                                .font(.headline)
                            Text("Automatically paste transcribed text into the active application when recording stops")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.switch)

                    if settings.autoPasteEnabled {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle")
                                .foregroundColor(.blue)
                            Text("Superkeet will simulate Cmd+V after transcription. This requires Accessibility permission.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(8)
                        .background(Color.blue.opacity(0.05))
                        .cornerRadius(8)
                    }
                }

                Divider()

                // Clipboard
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $settings.clipboardCopyEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Copy to Clipboard", systemImage: "clipboard")
                                .font(.headline)
                            Text("Always copy transcribed text to the system clipboard")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                }

                Divider()

                // Behavior summary
                VStack(alignment: .leading, spacing: 8) {
                    Label("Current Behavior", systemImage: "text.bubble")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 4) {
                        behaviorRow(
                            "After recording stops:",
                            detail: "Transcription is processed by Parakeet"
                        )
                        if settings.clipboardCopyEnabled {
                            behaviorRow(
                                "Then:",
                                detail: "Text is copied to clipboard"
                            )
                        }
                        if settings.autoPasteEnabled {
                            behaviorRow(
                                "Then:",
                                detail: "Text is automatically pasted (Cmd+V) into the previously active app"
                            )
                        }
                        if !settings.clipboardCopyEnabled && !settings.autoPasteEnabled {
                            behaviorRow(
                                "Note:",
                                detail: "Text will only appear in History. Enable at least one output method above."
                            )
                            .foregroundColor(.orange)
                        }
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.03))
                    .cornerRadius(8)
                }

                Spacer()
            }
            .padding(24)
        }
    }

    private func behaviorRow(_ label: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 120, alignment: .trailing)
            Text(detail)
                .font(.system(size: 11))
                .foregroundColor(.primary)
        }
    }
}

// MARK: - Visualization Option Card

struct VisualizationOption: View {
    let title: String
    let description: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .frame(height: 24)

                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(isSelected ? .primary : .secondary)

                Text(description)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.03))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08), lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}
