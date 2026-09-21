import Foundation
import os

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
        "vscode": Alias(name: "Visual Studio Code", bundleID: "com.microsoft.VSCode"),
        "camera": Alias(name: "Photo Booth", bundleID: "com.apple.PhotoBooth"),
        "photobooth": Alias(name: "Photo Booth", bundleID: "com.apple.PhotoBooth"),
        "email": Alias(name: "Mail", bundleID: "com.apple.mail"),
        "mail": Alias(name: "Mail", bundleID: "com.apple.mail"),
        "text messages": Alias(name: "Messages", bundleID: "com.apple.MobileSMS"),
        "imessage": Alias(name: "Messages", bundleID: "com.apple.MobileSMS"),
        "settings": Alias(name: "System Settings", bundleID: "com.apple.systempreferences"),
        "system settings": Alias(name: "System Settings", bundleID: "com.apple.systempreferences"),
        "system preferences": Alias(name: "System Settings", bundleID: "com.apple.systempreferences"),
        "preferences": Alias(name: "System Settings", bundleID: "com.apple.systempreferences"),
        "calc": Alias(name: "Calculator", bundleID: "com.apple.calculator")
    ]

    /// Edits allowed between a spoken name and an installed one that sounds the same.
    static let maximumFuzzyDistance = 3

    let directories: [URL]
    private let applicationsInDirectory: @Sendable (URL) -> [URL]

    init(
        directories: [URL] = AppResolver.defaultDirectories,
        applicationsInDirectory: @escaping @Sendable (URL) -> [URL] = AppResolver.applications
    ) {
        self.directories = directories
        self.applicationsInDirectory = applicationsInDirectory
    }

    /// `fuzzy` also accepts a sound-alike ("the crown" for Chrome). It is opt-in: the command
    /// that runs after the transcript may take the guess, but nothing launched while the user is
    /// still speaking should, so the live-speech detector resolves exactly.
    func resolve(_ name: String, bundleLookup: (String) -> URL? = { _ in nil }, fuzzy: Bool = false) -> URL? {
        let normalized = Self.normalizedName(name)
        guard !normalized.isEmpty else { return nil }
        let alias = Self.aliases[normalized]
        let bundleID = alias?.bundleID ?? (normalized.contains(".") ? name.trimmingCharacters(in: .whitespacesAndNewlines) : nil)
        if let bundleID, let registered = bundleLookup(bundleID), registered.isFileURL {
            return registered
        }
        let target = Self.normalizedName(alias?.name ?? normalized)
        if let match = exactMatch(target) { return match }
        return fuzzy ? fuzzyResolve(normalized, bundleLookup: bundleLookup) : nil
    }

    private func exactMatch(_ target: String) -> URL? {
        for directory in directories {
            let match = applicationsInDirectory(directory)
                .filter { $0.isFileURL && $0.pathExtension.lowercased() == "app" }
                .sorted { $0.path < $1.path }
                .first { Self.normalizedName($0.deletingPathExtension().lastPathComponent) == target }
            if let match { return match }
        }
        return nil
    }

    /// A misheard name ("the crown" for Chrome, "nodes" for Notes) resolves to the installed app
    /// or alias that sounds the same and is within a few edits. Partial names ("Heli") and whole
    /// phrases stay unresolved: a fuzzy match needs the same Soundex key, not just a prefix.
    private func fuzzyResolve(_ target: String, bundleLookup: (String) -> URL?) -> URL? {
        guard target.count >= 4, target.split(separator: " ").count <= 2 else { return nil }
        let key = Self.soundex(target)
        guard !key.isEmpty else { return nil }
        var best: (distance: Int, url: URL)?
        func consider(_ candidate: String, _ url: URL?) {
            guard let url, Self.soundex(candidate) == key else { return }
            let distance = Self.editDistance(target, candidate)
            guard distance <= Self.maximumFuzzyDistance, distance < (best?.distance ?? Int.max) else { return }
            best = (distance, url)
        }
        for directory in directories {
            for url in applicationsInDirectory(directory) where url.isFileURL && url.pathExtension.lowercased() == "app" {
                consider(Self.normalizedName(url.deletingPathExtension().lastPathComponent), url)
            }
        }
        for spoken in Self.aliases.keys.sorted() {
            guard let alias = Self.aliases[spoken] else { continue }
            consider(spoken, bundleLookup(alias.bundleID) ?? exactMatch(Self.normalizedName(alias.name)))
        }
        return best?.url
    }

    /// Classic Soundex over ASCII letters: first letter, then consonant classes with vowels
    /// dropped and adjacent duplicates collapsed, padded to four characters.
    static func soundex(_ text: String) -> String {
        let letters = text.lowercased().filter { $0.isLetter && $0.isASCII }
        guard let first = letters.first else { return "" }
        func code(_ character: Character) -> Character? {
            switch character {
            case "b", "f", "p", "v": return "1"
            case "c", "g", "j", "k", "q", "s", "x", "z": return "2"
            case "d", "t": return "3"
            case "l": return "4"
            case "m", "n": return "5"
            case "r": return "6"
            default: return nil
            }
        }
        var result = String(first).uppercased()
        var previous = code(first)
        for character in letters.dropFirst() where result.count < 4 {
            let current = code(character)
            if let current, current != previous { result.append(current) }
            if character != "h", character != "w" { previous = current }
        }
        return result.padding(toLength: 4, withPad: "0", startingAt: 0)
    }

    static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs), b = Array(rhs)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

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
        while let prefix = ["new ", "my ", "that "].first(where: { result.hasPrefix($0) }) {
            result = String(result.dropFirst(prefix.count))
        }
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
