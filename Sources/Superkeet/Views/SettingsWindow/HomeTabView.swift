import SwiftUI
import Carbon

/// Home tab showing stats and hotkey information
struct HomeTabView: View {
    @ObservedObject var historyStore = HistoryStore.shared
    @ObservedObject var settings = AppSettings.shared
    @State private var editingHotkey: EditingHotkey? = nil

    enum EditingHotkey {
        case toggle
        case pushToTalk
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                Text("Dashboard")
                    .font(.title)
                    .fontWeight(.bold)

                // Stats Grid
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 16) {
                    StatCard(
                        title: "Avg Speed",
                        value: String(format: "%.0f", historyStore.averageWordsPerMinute),
                        unit: "WPM",
                        icon: "speedometer",
                        color: .blue
                    )
                    StatCard(
                        title: "Words This Week",
                        value: formatNumber(historyStore.wordsTranscribedThisWeek),
                        unit: "words",
                        icon: "text.word.spacing",
                        color: .green
                    )
                    StatCard(
                        title: "Apps Used",
                        value: "\(historyStore.uniqueAppsUsedThisWeek)",
                        unit: "apps",
                        icon: "app.badge",
                        color: .purple
                    )
                    StatCard(
                        title: "Time Saved",
                        value: formatTimeSaved(historyStore.timeSavedThisWeekMinutes),
                        unit: timeSavedUnit(historyStore.timeSavedThisWeekMinutes),
                        icon: "clock.arrow.circlepath",
                        color: .orange
                    )
                }

                Divider()

                // Hotkeys Section
                VStack(alignment: .leading, spacing: 16) {
                    Text("Hotkeys")
                        .font(.title3)
                        .fontWeight(.semibold)

                    // Toggle Recording
                    HotkeyRow(
                        title: "Toggle Recording",
                        description: "Starts and stops recordings",
                        displayName: settings.toggleHotkeyDisplayName,
                        isEditing: editingHotkey == .toggle,
                        onClickBadge: {
                            editingHotkey = editingHotkey == .toggle ? nil : .toggle
                        }
                    )

                    if editingHotkey == .toggle {
                        InteractiveHotkeyRecorder(
                            onRecord: { keyCode, modifiers, name in
                                settings.toggleHotkeyKeyCode = keyCode
                                settings.toggleHotkeyModifierFlags = modifiers
                                settings.toggleHotkeyDisplayName = name
                                editingHotkey = nil
                            },
                            onCancel: { editingHotkey = nil }
                        )
                    }

                    // Push to Talk
                    HotkeyRow(
                        title: "Push to Talk",
                        description: "Hold to record, release when done",
                        displayName: settings.pttHotkeyDisplayName,
                        isEditing: editingHotkey == .pushToTalk,
                        onClickBadge: {
                            editingHotkey = editingHotkey == .pushToTalk ? nil : .pushToTalk
                        }
                    )

                    if editingHotkey == .pushToTalk {
                        InteractiveHotkeyRecorder(
                            onRecord: { keyCode, modifiers, name in
                                settings.pttHotkeyKeyCode = keyCode
                                settings.pttHotkeyModifierFlags = modifiers
                                settings.pttHotkeyDisplayName = name
                                editingHotkey = nil
                            },
                            onCancel: { editingHotkey = nil }
                        )
                    }
                }

                Spacer()
            }
            .padding(24)
        }
    }

    private func formatNumber(_ n: Int) -> String {
        if n >= 1000 {
            return String(format: "%.1fk", Double(n) / 1000.0)
        }
        return "\(n)"
    }

    private func formatTimeSaved(_ minutes: Double) -> String {
        if minutes >= 60 {
            return String(format: "%.1f", minutes / 60.0)
        }
        return String(format: "%.0f", minutes)
    }

    private func timeSavedUnit(_ minutes: Double) -> String {
        minutes >= 60 ? "hours" : "min"
    }
}

// MARK: - Stat Card

struct StatCard: View {
    let title: String
    let value: String
    let unit: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(color)
                Spacer()
            }
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
            Text(unit)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.7))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.06))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(color.opacity(0.1), lineWidth: 1)
        )
    }
}

// MARK: - Hotkey Row

struct HotkeyRow: View {
    let title: String
    let description: String
    let displayName: String
    let isEditing: Bool
    let onClickBadge: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: onClickBadge) {
                HotkeyBadge(displayName: displayName, isEditing: isEditing)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(10)
    }
}

// MARK: - Hotkey Badge

struct HotkeyBadge: View {
    let displayName: String
    var isEditing: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Text(displayName)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
            if !isEditing {
                Image(systemName: "pencil")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isEditing ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.08))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isEditing ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.15), lineWidth: 1)
        )
    }
}

// MARK: - Interactive Hotkey Recorder

/// Captures the next key combination the user presses and returns the keyCode, modifiers, and display name.
/// Uses NSEvent.addLocalMonitorForEvents to intercept key events within the app window.
struct InteractiveHotkeyRecorder: View {
    let onRecord: (Int, Int, String) -> Void
    let onCancel: () -> Void

    @State private var capturedName: String? = nil
    @State private var eventMonitor: Any? = nil
    @State private var flagsMonitor: Any? = nil

    var body: some View {
        VStack(spacing: 10) {
            if let name = capturedName {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Set to: \(name)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.green)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Press any key combination...")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.accentColor)
                }
            }

            HStack {
                // Preset buttons
                Button("⌥ Space") {
                    applyHotkey(keyCode: 49, modifiers: Int(CGEventFlags.maskAlternate.rawValue), name: "⌥ Space")
                }
                Button("fn") {
                    applyHotkey(keyCode: 63, modifiers: 0, name: "fn")
                }
                Button("⌃ Space") {
                    applyHotkey(keyCode: 49, modifiers: Int(CGEventFlags.maskControl.rawValue), name: "⌃ Space")
                }

                Spacer()

                Button("Cancel") {
                    cleanup()
                    onCancel()
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.05))
        .cornerRadius(10)
        .onAppear {
            startListening()
        }
        .onDisappear {
            cleanup()
        }
    }

    private func startListening() {
        // Monitor keyDown events
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = Int(event.keyCode)
            let modifiers = modifierFlagsToInt(event.modifierFlags)
            let name = displayNameForHotkey(keyCode: keyCode, modifierFlags: modifiers)
            applyHotkey(keyCode: keyCode, modifiers: modifiers, name: name)
            return nil  // Consume the event
        }

        // Monitor flagsChanged for modifier-only hotkeys (fn, etc.)
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let keyCode = Int(event.keyCode)
            // Only capture fn key (63) as a standalone hotkey via flagsChanged
            if keyCode == 63 {
                applyHotkey(keyCode: 63, modifiers: 0, name: "fn")
                return nil
            }
            // For other modifiers, let them through (they'll be captured with the next keyDown)
            return event
        }
    }

    private func applyHotkey(keyCode: Int, modifiers: Int, name: String) {
        capturedName = name
        cleanup()
        // Small delay so the user sees the confirmation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            onRecord(keyCode, modifiers, name)
        }
    }

    private func cleanup() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        if let monitor = flagsMonitor {
            NSEvent.removeMonitor(monitor)
            flagsMonitor = nil
        }
    }

    /// Extract the significant modifier flags as an Int matching CGEventFlags raw values
    private func modifierFlagsToInt(_ flags: NSEvent.ModifierFlags) -> Int {
        var result: UInt64 = 0
        if flags.contains(.command) { result |= CGEventFlags.maskCommand.rawValue }
        if flags.contains(.option) { result |= CGEventFlags.maskAlternate.rawValue }
        if flags.contains(.control) { result |= CGEventFlags.maskControl.rawValue }
        if flags.contains(.shift) { result |= CGEventFlags.maskShift.rawValue }
        return Int(result)
    }
}
