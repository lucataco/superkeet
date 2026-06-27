import SwiftUI

/// Output settings: visualization style, auto-paste, clipboard behavior
struct OutputTabView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var historyStore = HistoryStore.shared
    @ObservedObject var usageStats = UsageStatsStore.shared
    @State private var confirmClearHistory = false
    @State private var confirmResetUsageStats = false

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabHeader(
                title: "Output & Privacy",
                subtitle: "Transcribe, copy to clipboard, and keep automatic paste and saved history opt-in."
            )

            Form {
                Section {
                    HStack(spacing: 12) {
                        VisualizationOption(
                            title: "Classic",
                            description: "Expanded bar equalizer",
                            icon: "waveform.path",
                            isSelected: settings.recordingOverlayStyle == "classic"
                        ) {
                            settings.recordingOverlayStyle = "classic"
                        }

                        VisualizationOption(
                            title: "Mini",
                            description: "Compact dot pill",
                            icon: "ellipsis",
                            isSelected: settings.recordingOverlayStyle == "mini"
                        ) {
                            settings.recordingOverlayStyle = "mini"
                        }

                        VisualizationOption(
                            title: "None",
                            description: "No overlay",
                            icon: "eye.slash",
                            isSelected: settings.recordingOverlayStyle == "none"
                        ) {
                            settings.recordingOverlayStyle = "none"
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Recording Overlay")
                } footer: {
                    Text("Choose how the recording overlay appears while you're speaking.")
                }

                Section {
                    settingToggle(
                        isOn: $settings.fillerWordRemovalEnabled,
                        title: "Remove Filler Words",
                        subtitle: "Strip \"uh\", \"um\", \"er\", and \"hmm\" from transcriptions"
                    )
                    settingToggle(
                        isOn: $settings.clipboardCopyEnabled,
                        title: "Copy to Clipboard",
                        subtitle: "Copy each transcription so you can paste it where you want"
                    )
                } header: {
                    Text("Transcription")
                }

                Section {
                    settingToggle(
                        isOn: $settings.autoPasteEnabled,
                        title: "Paste Automatically",
                        subtitle: "Paste into the previous app after transcription"
                    )
                } header: {
                    Text("Auto-Paste")
                } footer: {
                    Label(
                        "Best for power users. Depends on Accessibility access and can paste into the wrong place if focus changes.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }

                Section {
                    settingToggle(
                        isOn: $settings.saveHistoryEnabled,
                        title: "Save History",
                        subtitle: "Keep past transcriptions in the local history list on this Mac"
                    )

                    LabeledContent {
                        Button("Clear History") {
                            confirmClearHistory = true
                        }
                        .disabled(historyStore.records.isEmpty)
                    } label: {
                        rowLabel(
                            "Stored Items",
                            "\(historyStore.records.count) transcription\(historyStore.records.count == 1 ? "" : "s") saved on this Mac"
                        )
                    }

                    LabeledContent {
                        Button("Reset Stats") {
                            confirmResetUsageStats = true
                        }
                        .disabled(!usageStats.hasData)
                    } label: {
                        rowLabel(
                            "Usage Stats",
                            usageStats.hasData
                                ? "\(usageStats.totalWords) words across \(usageStats.totalSessions) session\(usageStats.totalSessions == 1 ? "" : "s")"
                                : "No usage stats saved yet"
                        )
                    }
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("History and usage stats are stored locally in ~/Library/Application Support/Superkeet. Usage stats never include transcribed text.")
                }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        behaviorRow("After recording", detail: "Transcription is processed by Parakeet")
                        if settings.saveHistoryEnabled {
                            behaviorRow("Then", detail: "Text is saved in local history")
                        }
                        if settings.clipboardCopyEnabled {
                            behaviorRow("Then", detail: "Text is copied to clipboard")
                        }
                        if settings.autoPasteEnabled {
                            behaviorRow("Then", detail: "Text is pasted (⌘V) into the previously active app")
                        }
                        if !settings.clipboardCopyEnabled && !settings.autoPasteEnabled {
                            behaviorRow(
                                "Note",
                                detail: settings.saveHistoryEnabled
                                    ? "Text will only appear in History. Enable clipboard copy for an easier default flow."
                                    : "Text will not be retained anywhere. Enable history or clipboard copy before recording."
                            )
                            .foregroundColor(.orange)
                        }
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text("What Happens After Recording")
                }
            }
            .formStyle(.grouped)
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
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 92, alignment: .trailing)
            Text(detail)
                .font(.system(size: 11))
                .foregroundColor(.primary)
            Spacer(minLength: 0)
        }
    }

    /// A native-weight toggle row: title plus secondary subtitle, trailing switch.
    private func settingToggle(isOn: Binding<Bool>, title: String, subtitle: String) -> some View {
        Toggle(isOn: isOn) {
            rowLabel(title, subtitle)
        }
    }

    /// Standard two-line label (primary title + secondary subtitle) for form rows.
    private func rowLabel(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Visualization Option Card

private struct VisualizationOption: View {
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
