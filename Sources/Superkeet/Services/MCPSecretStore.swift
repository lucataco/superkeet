import Foundation
import Security
import os.log

protocol MCPSecretStoring: AnyObject {
    func secretEnvironment(for name: String) throws -> [String: String]
    func setSecretEnvironment(_ environment: [String: String], for name: String) throws
    func removeSecretEnvironment(for name: String)
}

enum MCPSecretStoreError: LocalizedError {
    case keychain(OSStatus)
    case unreadable(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return "Couldn't save the server's secrets to the Keychain (\(Self.detail(status))). The server was not saved."
        case .unreadable(let status):
            return "Couldn't read the server's secrets from the Keychain (\(Self.detail(status)))."
        }
    }

    private static func detail(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "error \(status)"
    }
}

final class KeychainMCPSecretStore: MCPSecretStoring {
    static let defaultService = "com.superkeet.app.mcp"

    private let service: String
    private let log = Logger(subsystem: "com.superkeet.app", category: "MCPSecretStore")

    init(service: String = KeychainMCPSecretStore.defaultService) {
        self.service = service
    }

    func secretEnvironment(for name: String) throws -> [String: String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return [:] }
        guard status == errSecSuccess,
              let data = item as? Data,
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            log.error("Failed to read MCP secrets for \(name, privacy: .public): \(status)")
            throw MCPSecretStoreError.unreadable(status == errSecSuccess ? errSecDecode : status)
        }
        return decoded
    }

    func setSecretEnvironment(_ environment: [String: String], for name: String) throws {
        let data = try JSONEncoder().encode(environment)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addition = base
            addition[kSecValueData as String] = data
            addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addition as CFDictionary, nil)
            if addStatus != errSecSuccess {
                log.error("Failed to store MCP secrets for \(name, privacy: .public): \(addStatus)")
                throw MCPSecretStoreError.keychain(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            log.error("Failed to update MCP secrets for \(name, privacy: .public): \(updateStatus)")
            throw MCPSecretStoreError.keychain(updateStatus)
        }
    }

    func removeSecretEnvironment(for name: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            log.error("Failed to remove MCP secrets for \(name, privacy: .public): \(status)")
        }
    }
}
