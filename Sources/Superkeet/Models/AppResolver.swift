import Foundation
import os

/// Name matching and directory precedence are independent of Launch Services.
/// Tests supply a directory inventory and a bundle lookup without opening apps.
struct AppResolver: Sendable {
    static var defaultDirectories: [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
         URL(fileURLWithPath: "/System/Applications", isDirectory: true)]
    }

    private struct Alias: Sendable {
        let name: String
        let bundleID: String
    }

    private static let aliases: [String: Alias] = [
        "chrome": Alias(name: "Google Chrome", bundleID: "com.google.Chrome"),
        "google chrome": Alias(name: "Google Chrome", bundleID: "com.google.Chrome"),
        "edge": Alias(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac"),
        "microsoft edge": Alias(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac"),
        "safari": Alias(name: "Safari", bundleID: "com.apple.Safari"),
        "firefox": Alias(name: "Firefox", bundleID: "org.mozilla.firefox"),
        "discord": Alias(name: "Discord", bundleID: "com.hnc.Discord"),
        "vs code": Alias(name: "Visual Studio Code", bundleID: "com.microsoft.VSCode"),
        "vscode": Alias(name: "Visual Studio Code", bundleID: "com.microsoft.VSCode")
    ]

    let directories: [URL]
    private let applicationsInDirectory: @Sendable (URL) -> [URL]

    init(
        directories: [URL] = AppResolver.defaultDirectories,
        applicationsInDirectory: @escaping @Sendable (URL) -> [URL] = AppResolver.applications
    ) {
        self.directories = directories
        self.applicationsInDirectory = applicationsInDirectory
    }

    func resolve(_ name: String, bundleLookup: (String) -> URL? = { _ in nil }) -> URL? {
        let normalized = Self.normalizedName(name)
        guard !normalized.isEmpty else { return nil }
        let alias = Self.aliases[normalized]
        let bundleID = alias?.bundleID ?? (normalized.contains(".") ? name.trimmingCharacters(in: .whitespacesAndNewlines) : nil)
        if let bundleID, let registered = bundleLookup(bundleID), registered.isFileURL {
            return registered
        }
        let target = Self.normalizedName(alias?.name ?? normalized)
        for directory in directories {
            let match = applicationsInDirectory(directory)
                .filter { $0.isFileURL && $0.pathExtension.lowercased() == "app" }
                .sorted { $0.path < $1.path }
                .first { Self.normalizedName($0.deletingPathExtension().lastPathComponent) == target }
            if let match { return match }
        }
        return nil
    }

    /// Display names of every installed app across the search directories,
    /// de-duplicated case-insensitively and sorted. Used to bias speech
    /// recognition toward names the user can actually open.
    func installedApplicationNames() -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for directory in directories {
            for url in applicationsInDirectory(directory) where url.isFileURL && url.pathExtension.lowercased() == "app" {
                let name = url.deletingPathExtension().lastPathComponent
                guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
                names.append(name)
            }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// A resolver that scans each directory once and answers later lookups from
    /// memory. Scanning `/Applications` takes hundreds of milliseconds, so anything
    /// that resolves names repeatedly (for example on every interim transcript)
    /// should use this and recreate it when a fresh inventory is wanted.
    func memoized() -> AppResolver {
        let cache = DirectoryListingCache(lister: applicationsInDirectory)
        return AppResolver(directories: directories, applicationsInDirectory: { cache.applications(in: $0) })
    }

    private final class DirectoryListingCache: Sendable {
        private let lister: @Sendable (URL) -> [URL]
        private let listings = OSAllocatedUnfairLock<[URL: [URL]]>(initialState: [:])

        init(lister: @escaping @Sendable (URL) -> [URL]) {
            self.lister = lister
        }

        func applications(in directory: URL) -> [URL] {
            if let cached = listings.withLock({ $0[directory] }) { return cached }
            let listed = lister(directory)
            listings.withLock { $0[directory] = listed }
            return listed
        }
    }

    static func normalizedName(_ name: String) -> String {
        let edges = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        var result = name.trimmingCharacters(in: edges).lowercased()
        if result.hasSuffix(".app") { result = String(result.dropLast(4)) }
        result = result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if result.hasPrefix("the ") { result = String(result.dropFirst(4)) }
        while let suffix = [" browser", " app"].first(where: { result.hasSuffix($0) }) {
            result = String(result.dropLast(suffix.count)).trimmingCharacters(in: edges)
        }
        return result.trimmingCharacters(in: edges)
    }

    private static func applications(in directory: URL) -> [URL] {
        guard let entries = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        return entries.compactMap { entry in
            guard let url = entry as? URL, url.pathExtension.lowercased() == "app",
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            return url
        }
    }
}
