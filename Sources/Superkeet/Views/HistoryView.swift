import SwiftUI

struct HistoryView: View {
    @ObservedObject var historyStore = HistoryStore.shared
    @ObservedObject var settings = AppSettings.shared
    @State private var searchText: String = ""
    @State private var selectedRecord: TranscriptionRecord?
    @State private var confirmClearAll: Bool = false
    @State private var copiedRecordID: UUID?
    @State private var copiedResetTask: DispatchWorkItem?

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
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("History")
                        .font(.title2)
                        .fontWeight(.semibold)
                    if !historyStore.records.isEmpty {
                        Text("Double-click a row or press ⌘C to copy it")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
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

            if let issue = historyStore.persistenceIssue {
                Text(issue).font(.caption).foregroundStyle(.orange).textSelection(.enabled).padding(.horizontal)
            }
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
                            HistoryRowView(
                                record: record,
                                isSelected: selectedRecord?.id == record.id,
                                showsCopied: copiedRecordID == record.id
                            )
                                .onTapGesture(count: 2) {
                                    copy(record)
                                }
                                .onTapGesture(count: 1) {
                                    selectedRecord = record
                                }
                                .contextMenu {
                                    Button("Copy Text") {
                                        copy(record)
                                    }
                                    if let original = record.rawText {
                                        Button("Copy Original Transcript") { PasteService.shared.copyToClipboard(original) }
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
                // Hidden ⌘C target so the selected row copies like any other list.
                .background {
                    Button("Copy") {
                        if let selectedRecord { copy(selectedRecord) }
                    }
                    .keyboardShortcut("c", modifiers: .command)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
                }
            }
        }
        .frame(minWidth: 480, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
    }

    private func copy(_ record: TranscriptionRecord) {
        PasteService.shared.copyToClipboard(record.text)
        selectedRecord = record
        copiedResetTask?.cancel()
        withAnimation(.easeInOut(duration: 0.15)) { copiedRecordID = record.id }
        let reset = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.2)) { copiedRecordID = nil }
        }
        copiedResetTask = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: reset)
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
    var showsCopied: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: "app.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(record.activeAppName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }

                Spacer()

                if showsCopied {
                    Label("Copied", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.green)
                        .transition(.opacity)
                } else {
                    Text(record.timestamp, style: .relative)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.7))
                }
            }

            if record.isPartial == true {
                Label("Partial transcript", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text(record.text)
                .font(.system(size: 13))
                .lineLimit(3)
                .foregroundColor(.primary)

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
