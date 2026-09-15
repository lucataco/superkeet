import Foundation

enum MCPExecutableResolver {
    static func resolve(
        command: String,
        searchPath: String,
        isExecutable: (String) -> Bool = defaultIsExecutable
    ) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.contains("/") {
            let expanded = (trimmed as NSString).expandingTildeInPath
            return isExecutable(expanded) ? expanded : nil
        }

        for directory in searchPath.split(separator: ":").map(String.init) where !directory.isEmpty {
            let candidate = (directory as NSString).appendingPathComponent(trimmed)
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    static func defaultIsExecutable(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }
}
