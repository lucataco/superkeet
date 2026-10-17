import Foundation

enum AppPaths {
    static var applicationSupportDirectory: URL {
        let directory = isRunningTests ? testSupportDirectory : userSupportDirectory
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    private static var userSupportDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Superkeet", isDirectory: true)
    }

    /// Tests that reach a `.shared` store must never write fixtures into the user's real history,
    /// stats, MCP config or action log.
    static let isRunningTests = NSClassFromString("XCTestCase") != nil

    private static let testSupportDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SuperkeetTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
}
