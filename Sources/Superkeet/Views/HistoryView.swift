import SwiftUI

/// Displays transcription history with rich context
struct HistoryView: View {
    @ObservedObject var historyStore = HistoryStore.shared
    @ObservedObject var settings = AppSettings.shared
    @State private var searchText: String = ""
    @State private var selectedRecord: TranscriptionRecord?
    @State private var confirmClearAll: Bool = false

    var filteredRecords: [TranscriptionRecord] {
        if searchText.isEmpty {
            return historyStore.records
        }
        return historyStore.records.filter {
            $0.text.localizedCaseInsensitiveContains(searchText) ||
            $0.activeAppName.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("History")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                if !historyStore.records.isEmpty {
                    Button("Clear All") {
                        confirmClearAll = true
                    }
                    .foregroundColor(.red)
                    .buttonStyle(.plain)
                    .font(.caption)
                    .alert("Clear All History?", isPresented: $confirmClearAll) {
                        Button("Delete All", role: .destructive) {
                            historyStore.clearHistory()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This will permanently delete all \(historyStore.records.count) transcription records. This cannot be undone.")
                    }
                }
            }
            .padding()

            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search transcriptions...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .cardStyle(padding: 8, cornerRadius: 8)
            .padding(.horizontal)
            .padding(.bottom, 8)

            Divider()

            // Records list
            if filteredRecords.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: emptyStateIcon)
                        .font(.system(size: 40))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text(emptyStateTitle)
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text(emptyStateMessage)
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(filteredRecords) { record in
                            HistoryRowView(record: record, isSelected: selectedRecord?.id == record.id)
                                .onTapGesture {
                                    selectedRecord = record
                                }
                                .contextMenu {
                                    Button("Copy Text") {
                                        PasteService.shared.copyToClipboard(record.text)
                                    }
                                    Divider()
                                    Button("Delete", role: .destructive) {
                                        historyStore.deleteRecord(record)
                                    }
                                }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(minWidth: 480, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
    }

    private var emptyStateIcon: String {
        if !searchText.isEmpty { return "magnifyingglass" }
        return settings.saveHistoryEnabled ? "waveform" : "lock.shield"
    }

    private var emptyStateTitle: String {
        if !searchText.isEmpty { return "No results found" }
        return settings.saveHistoryEnabled ? "No transcriptions yet" : "History is off"
    }

    private var emptyStateMessage: String {
        if !searchText.isEmpty { return "Try a different search term" }
        if settings.saveHistoryEnabled {
            return "Use \(settings.toggleHotkeyDisplayName) or the menu bar to start recording"
        }
        return "Turn on Save History in Settings > Output & Privacy to keep future transcriptions on this Mac."
    }
}

struct HistoryRowView: View {
    let record: TranscriptionRecord
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Top row: app name + timestamp
            HStack {
                // App icon placeholder + name
                HStack(spacing: 4) {
                    Image(systemName: "app.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(record.activeAppName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text(record.timestamp, style: .relative)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.7))
            }

            // Transcription text
            Text(record.text)
                .font(.system(size: 13))
                .lineLimit(3)
                .foregroundColor(.primary)

            // Bottom row: stats
            HStack(spacing: 12) {
                Label("\(record.wordCount) words", systemImage: "textformat")
                Label(String(format: "%.1fs", record.durationSeconds), systemImage: "clock")
                Label(String(format: "%.0f WPM", record.wordsPerMinute), systemImage: "speedometer")
            }
            .font(.system(size: 10))
            .foregroundColor(.secondary.opacity(0.7))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        .contentShape(Rectangle())
    }
}
