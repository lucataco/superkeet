import Foundation

/// Web addresses as people say them: "x dot com", "youtube dot com slash trending". The
/// recogniser writes them as words, so they are joined back into `x.com` and
/// `youtube.com/trending` before URL detection runs.
enum SpokenURL {
    /// Endings people actually say. "polka dot dress" must stay words, so an arbitrary
    /// two-to-six-letter word after "dot" is not enough.
    static let topLevelDomains = [
        "com", "net", "org", "io", "ai", "dev", "app", "co", "edu", "gov", "me", "tv", "us", "uk", "ca", "de", "fr",
        "es", "it", "nl", "xyz", "info", "gg", "ly", "fm", "so", "to", "be", "ch", "au", "in", "jp"
    ]

    private static let domain: NSRegularExpression? = {
        let endings = topLevelDomains.joined(separator: "|")
        return try? NSRegularExpression(pattern: #"\b([a-z0-9-]+)\s+dot\s+(\#(endings))\b"#, options: .caseInsensitive)
    }()
    /// "www dot youtube.com": a label spoken before an address already joined.
    private static let subdomain = try? NSRegularExpression(
        pattern: #"\b([a-z0-9-]+)\s+dot\s+([a-z0-9-]+\.[a-z]{2,6})\b"#, options: .caseInsensitive
    )
    private static let slash = try? NSRegularExpression(
        pattern: #"\b([a-z0-9-]+\.[a-z]{2,6}(?:/[a-z0-9._~-]*)?)\s+slash\s+([a-z0-9._~-]+)"#, options: .caseInsensitive
    )

    static func normalize(_ text: String) -> String {
        guard let domain, let subdomain, let slash else { return text }
        var result = replacing(domain, in: text, with: "$1.$2")
        result = replacing(subdomain, in: result, with: "$1.$2")
        return replacing(slash, in: result, with: "$1/$2")
    }

    private static func replacing(_ pattern: NSRegularExpression, in text: String, with template: String) -> String {
        var result = text
        // Repeat so "www dot example dot com slash a slash b" collapses fully.
        for _ in 0..<4 {
            let range = NSRange(result.startIndex..., in: result)
            let replaced = pattern.stringByReplacingMatches(in: result, range: range, withTemplate: template)
            if replaced == result { break }
            result = replaced
        }
        return result
    }
}
