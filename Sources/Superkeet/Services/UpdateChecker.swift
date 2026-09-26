import Foundation
import os.log

private let updateLog = Logger(subsystem: "com.superkeet.app", category: "UpdateChecker")

/// Asks GitHub for the latest Superkeet release. Only runs when the user clicks "Check for
/// Updates"; nothing is sent except the request itself.
enum UpdateChecker {
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/lucataco/superkeet/releases/latest")
    static let releasesPageURL = URL(string: "https://github.com/lucataco/superkeet/releases/latest")

    enum Result: Equatable {
        case upToDate(current: String)
        case available(version: String, url: URL)
        case failed(String)
    }

    struct Release: Decodable {
        let tagName: String
        let htmlURL: URL
        let draft: Bool?
        let prerelease: Bool?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case draft, prerelease
        }
    }

    static func check(
        currentVersion: String = AppVersion.current.shortVersion,
        fetch: @Sendable (URL) async throws -> Data = { url in
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            return data
        }
    ) async -> Result {
        guard let url = latestReleaseURL else { return .failed("The update address is invalid.") }
        do {
            let release = try JSONDecoder().decode(Release.self, from: try await fetch(url))
            return evaluate(release: release, currentVersion: currentVersion)
        } catch {
            updateLog.error("Update check failed: \(error.localizedDescription)")
            return .failed("Couldn't check for updates. \(error.localizedDescription)")
        }
    }

    static func evaluate(release: Release, currentVersion: String) -> Result {
        let latest = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
        guard release.draft != true, release.prerelease != true,
              isVersion(latest, newerThan: currentVersion) else { return .upToDate(current: currentVersion) }
        return .available(version: latest, url: release.htmlURL)
    }

    /// Numeric comparison of dotted versions: "1.10.0" is newer than "1.9.2".
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let lhs = parts(candidate), rhs = parts(current)
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }
}
