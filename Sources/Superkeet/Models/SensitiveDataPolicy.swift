import Foundation

enum SensitiveDataPolicy {
    private static let markers = [
        "token", "password", "passwd", "secret", "apikey", "api_key",
        "authorization", "auth", "cookie", "credential", "privatekey", "private_key", "session"
    ]

    static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
        return markers.contains { normalized.contains($0) }
    }
}
