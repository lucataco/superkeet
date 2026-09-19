import SwiftUI

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
                subtitle: "Every transcript is copied to the clipboard. Automatic paste and saved history are opt-in."
            )

            Form {
                Section {
                    settingToggle(
                        isOn: $settings.fillerWordRemovalEnabled,
                        title: "Remove Filler Words",
                        subtitle: "Drop ‘uh’ and ‘um’ from transcripts"
                    )
                    settingToggle(
                        isOn: $settings.spokenCorrectionsEnabled,
                        title: "Spoken Correction Commands",
                        subtitle: "Say ‘scratch that’, ‘replace X with Y’, or ‘undo last correction’ as its own sentence"
                    )
                } header: {
                    Text("Transcription")
                } footer: {
                    Text("Commands must stand alone, separated by punctuation or a pause. The original transcript is always recoverable from the menu bar.")
                }

                Section {
                    settingToggle(
                        isOn: $settings.autoPasteEnabled,
                        title: "Paste Automatically",
                        subtitle: "Paste into the app you were using when you started recording"
                    )
                    if settings.autoPasteEnabled {
                        settingToggle(
                            isOn: $settings.clipboardCopyEnabled,
                            title: "Keep Transcript on Clipboard",
                            subtitle: "Off restores whatever you had copied before the paste"
                        )
                    }
                } header: {
                    Text("Output")
                } footer: {
                    if settings.autoPasteEnabled {
                        Label(
                            "Needs Accessibility access. If focus changes before the paste lands, the text stays on the clipboard.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.orange)
                    } else {
                        Text("Every transcript is copied to the clipboard, so ⌘V pastes it wherever you are.")
                    }
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
                    if let issue = historyStore.persistenceIssue {
                        Text(issue).foregroundStyle(.orange).textSelection(.enabled)
                    }
                    if let issue = usageStats.persistenceIssue {
                        Text(issue).foregroundStyle(.orange).textSelection(.enabled)
                    }
                    Text("History and usage stats are stored locally in ~/Library/Application Support/Superkeet. Usage stats never include transcribed text.")
                }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        behaviorRow("After recording", detail: "Transcription is processed by Parakeet")
                        if settings.saveHistoryEnabled {
                            behaviorRow("Then", detail: "Text is saved in local history")
                        }
                        behaviorRow("Then", detail: "Text is copied to the clipboard")
                        if settings.autoPasteEnabled {
                            behaviorRow("Then", detail: "Text is pasted (⌘V) into the previously active app")
                            if !settings.clipboardCopyEnabled {
                                behaviorRow("Finally", detail: "Your previous clipboard is restored")
                            }
                        }
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text("What Happens After Recording")
                }

                Section("Last Transcript & Recovery") {
                    LastTranscriptView()
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

    private func settingToggle(isOn: Binding<Bool>, title: String, subtitle: String) -> some View {
        Toggle(isOn: isOn) {
            rowLabel(title, subtitle)
        }
    }

}
