import SwiftUI

/// The three-number summary shown at the top of Settings: words dictated,
/// average speaking rate, and estimated time saved. Backed by the privacy-safe
/// `UsageStatsStore`, so it works whether or not history saving is enabled.
struct StatsHeaderView: View {
    @ObservedObject var stats = UsageStatsStore.shared

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            StatTile(
                value: stats.hasData ? Formatters.compact(stats.totalWords) : "—",
                label: "Words Dictated",
                systemImage: "text.word.spacing"
            )
            StatTile(
                value: stats.hasData ? "\(Int(stats.averageWordsPerMinute.rounded()))" : "—",
                label: "Avg Speaking Rate",
                unit: "WPM",
                systemImage: "speedometer"
            )
            StatTile(
                value: stats.hasData ? Formatters.duration(minutes: stats.timeSavedMinutes) : "—",
                label: "Time Saved",
                systemImage: "clock.arrow.circlepath"
            )
        }
    }
}

// MARK: - Stat Tile

struct StatTile: View {
    let value: String
    let label: String
    var unit: String? = nil
    let systemImage: String

    var body: some View {
        VStack(spacing: Theme.Spacing.xs) {
            Image(systemName: systemImage)
                .font(.system(size: 14))
                .foregroundColor(.accentColor)

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                if let unit {
                    Text(unit)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)

            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.lg)
        .padding(.horizontal, Theme.Spacing.sm)
        .cardStyle(padding: 0, cornerRadius: Theme.Radius.lg)
    }
}

// MARK: - Formatting helpers

private enum Formatters {
    /// Compact integer formatting, e.g. 1234 -> "1.2k".
    static func compact(_ value: Int) -> String {
        switch value {
        case 1_000_000...:
            return String(format: "%.1fM", Double(value) / 1_000_000)
        case 10_000...:
            return String(format: "%.0fk", Double(value) / 1_000)
        case 1_000...:
            return String(format: "%.1fk", Double(value) / 1_000)
        default:
            return "\(value)"
        }
    }

    /// Human-friendly duration from minutes, e.g. "45m", "2.5h".
    static func duration(minutes: Double) -> String {
        if minutes < 1 {
            return "<1m"
        }
        if minutes < 60 {
            return "\(Int(minutes.rounded()))m"
        }
        let hours = minutes / 60
        if hours < 10 {
            return String(format: "%.1fh", hours)
        }
        return "\(Int(hours.rounded()))h"
    }
}
