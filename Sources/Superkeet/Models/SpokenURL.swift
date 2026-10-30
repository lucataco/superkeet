import Foundation

enum SpokenURL {
    static let topLevelDomains = [
        "com", "net", "org", "io", "ai", "dev", "app", "co", "edu", "gov", "me", "tv", "us", "uk", "ca", "de", "fr",
        "es", "it", "nl", "xyz", "info", "gg", "ly", "fm", "so", "to", "be", "ch", "au", "in", "jp"
    ]

    private static let domain: NSRegularExpression? = {
        let endings = topLevelDomains.joined(separator: "|")
        return try? NSRegularExpression(pattern: #"\b([a-z0-9-]+)\s+dot\s+(\#(endings))\b"#, options: .caseInsensitive)
    }()
    private static let subdomain = try? NSRegularExpression(
        pattern: #"\b([a-z0-9-]+)\s+dot\s+([a-z0-9-]+\.[a-z]{2,6})\b"#, options: .caseInsensitive
    )
    private static let slash = try? NSRegularExpression(
        pattern: #"\b([a-z0-9-]+\.[a-z]{2,6}(?:/[a-z0-9._~-]*)?)\s+slash\s+([a-z0-9._~-]+)"#, options: .caseInsensitive
    )

    /// Whether the address ends in something a longer ending could still extend, as a partial
    /// transcript does for `x.co` while the speaker is saying `x.com`.
    static func topLevelDomainMayGrow(in url: URL) -> Bool {
        guard let ending = url.host?.split(separator: ".").last.map({ String($0).lowercased() }) else { return false }
        return topLevelDomains.contains { $0 != ending && $0.hasPrefix(ending) }
    }

    static func normalize(_ text: String) -> String {
        guard let domain, let subdomain, let slash else { return text }
        var result = replacing(domain, in: text, with: "$1.$2")
        result = replacing(subdomain, in: result, with: "$1.$2")
        return replacing(slash, in: result, with: "$1/$2")
    }

    private static func replacing(_ pattern: NSRegularExpression, in text: String, with template: String) -> String {
        var result = text
        for _ in 0..<4 {
            let range = NSRange(result.startIndex..., in: result)
            let replaced = pattern.stringByReplacingMatches(in: result, range: range, withTemplate: template)
            if replaced == result { break }
            result = replaced
        }
        return result
    }
}
