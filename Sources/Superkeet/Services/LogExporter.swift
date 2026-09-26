import AppKit
import Foundation
import OSLog
import UniformTypeIdentifiers

private let exportLog = Logger(subsystem: "com.superkeet.app", category: "LogExporter")

/// Collects Superkeet's own unified-log messages since launch into a text file for bug reports.
/// Values logged as private stay redacted, as they do in Console.
enum LogExporter {
    static let subsystem = "com.superkeet.app"

    struct Line: Equatable {
        let date: Date
        let level: String
        let category: String
        let message: String
    }

    static func collect(since: Date = Date().addingTimeInterval(-24 * 60 * 60)) throws -> [Line] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(date: since)
        let predicate = NSPredicate(format: "subsystem == %@", subsystem)
        return try store.getEntries(at: position, matching: predicate).compactMap { entry in
            guard let log = entry as? OSLogEntryLog else { return nil }
            return Line(date: log.date, level: levelName(log.level), category: log.category, message: log.composedMessage)
        }
    }

    static func render(_ lines: [Line], header: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let body = lines.map { "\(formatter.string(from: $0.date)) [\($0.level)] \($0.category): \($0.message)" }
        return ([header, "", "Log (\(lines.count) entries since launch)", String(repeating: "-", count: 40)] + body)
            .joined(separator: "\n") + "\n"
    }

    static func levelName(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "notice"
        case .error: return "error"
        case .fault: return "fault"
        default: return "log"
        }
    }

    /// Asks where to save, then writes the diagnostics summary followed by the log.
    @MainActor
    static func exportWithSavePanel() -> String? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Superkeet Logs \(Self.fileDateFormatter.string(from: Date())).txt"
        panel.allowedContentTypes = [.plainText]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let text = render(try collect(), header: DiagnosticsExporter.currentReport())
            try text.write(to: url, atomically: true, encoding: .utf8)
            exportLog.info("Exported logs")
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return nil
        } catch {
            exportLog.error("Log export failed: \(error.localizedDescription)")
            return "Couldn't export logs: \(error.localizedDescription)"
        }
    }

    private static let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return formatter
    }()
}
