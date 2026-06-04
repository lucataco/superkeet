import SwiftUI

/// Output settings: visualization style, auto-paste, clipboard behavior
struct OutputTabView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var historyStore = HistoryStore.shared
    @ObservedObject var usageStats = UsageStatsStore.shared
    @State private var confirmClearHistory = false
    @State private var confirmResetUsageStats = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Output & Privacy")
                    .font(.title)
                    .fontWeight(.bold)

                Text("Keep the default flow simple: transcribe, copy to clipboard, and leave both automatic paste and saved history as opt-in.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

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

                // Filler Word Removal
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $settings.fillerWordRemovalEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Remove Filler Words", systemImage: "textformat.alt")
                                .font(.headline)
                            Text("Strip filler words like \"uh\", \"um\", \"er\", and \"hmm\" from transcriptions")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                }

                Divider()

                // Clipboard
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $settings.clipboardCopyEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Copy to Clipboard", systemImage: "clipboard")
                                .font(.headline)
                            Text("Copy each transcription so you can paste it where you want")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                }

                Divider()

                // Auto-paste
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $settings.autoPasteEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Paste Automatically", systemImage: "doc.on.clipboard")
                                .font(.headline)
                            Text("Paste into the previous app automatically after transcription")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.switch)

                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                        Text("Best for power users. This depends on Accessibility access and can paste into the wrong place if focus changes.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.06))
                    .cornerRadius(8)
                }

                Divider()

                // Privacy
                VStack(alignment: .leading, spacing: 12) {
                    Label("Privacy", systemImage: "lock.shield")
                        .font(.headline)

                    Toggle(isOn: $settings.saveHistoryEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Save History")
                                .font(.system(size: 13, weight: .medium))
                            Text("Opt in to keep past transcriptions in the local history list on this Mac")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.switch)

                    Text("Saved history is stored locally in plain JSON at ~/Library/Application Support/Superkeet/history.json with restricted file permissions.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Stored Items")
                                .font(.system(size: 13, weight: .medium))
                            Text("\(historyStore.records.count) transcription\(historyStore.records.count == 1 ? "" : "s") currently saved on this Mac")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Clear History") {
                            confirmClearHistory = true
                        }
                        .disabled(historyStore.records.isEmpty)
                    }

                    Divider()

                    Text("Usage stats store counts, durations, and sessions only — never transcribed text — at ~/Library/Application Support/Superkeet/usage-stats.json.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Usage Stats")
                                .font(.system(size: 13, weight: .medium))
                            Text(usageStats.hasData ? "\(usageStats.totalWords) words across \(usageStats.totalSessions) session\(usageStats.totalSessions == 1 ? "" : "s")" : "No usage stats saved yet")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Reset Stats") {
                            confirmResetUsageStats = true
                        }
                        .disabled(!usageStats.hasData)
                    }
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
                        if settings.saveHistoryEnabled {
                            behaviorRow(
                                "Then:",
                                detail: "Text is saved in local history"
                            )
                        }
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
                                detail: settings.saveHistoryEnabled ? "Text will only appear in History. Enable clipboard copy if you want an easier default flow." : "Text will not be retained anywhere. Enable history or clipboard copy before recording."
                            )
                            .foregroundColor(.orange)
                        }
                    }
                    .cardStyle(cornerRadius: 8)
                }

                Spacer()
            }
            .padding(24)
        }
        .alert("Clear saved history?", isPresented: $confirmClearHistory) {
            Button("Clear", role: .destructive) {
                historyStore.clearHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all saved transcriptions from this Mac.")
        }
        .alert("Reset usage stats?", isPresented: $confirmResetUsageStats) {
            Button("Reset", role: .destructive) {
                usageStats.reset()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears aggregate counts like words dictated, average speaking rate, and time saved. It does not affect saved transcription history.")
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
