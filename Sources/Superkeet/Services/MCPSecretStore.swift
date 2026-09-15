import Foundation
import Security
import os.log

protocol MCPSecretStoring: AnyObject {
    func secretEnvironment(for name: String) -> [String: String]
    func setSecretEnvironment(_ environment: [String: String], for name: String)
    func removeSecretEnvironment(for name: String)
}

final class KeychainMCPSecretStore: MCPSecretStoring {
    static let defaultService = "com.superkeet.app.mcp"

    private let service: String
    private let log = Logger(subsystem: "com.superkeet.app", category: "MCPSecretStore")

    init(service: String = KeychainMCPSecretStore.defaultService) {
        self.service = service
    }

    func secretEnvironment(for name: String) -> [String: String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    func setSecretEnvironment(_ environment: [String: String], for name: String) {
        guard let data = try? JSONEncoder().encode(environment) else { return }
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
            }
        } else if updateStatus != errSecSuccess {
            log.error("Failed to update MCP secrets for \(name, privacy: .public): \(updateStatus)")
        }
    }

    func removeSecretEnvironment(for name: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name
        ]
        SecItemDelete(query as CFDictionary)
    }
}
