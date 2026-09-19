import Foundation
import CoreFoundation

enum ActionJSON {
    static let maximumStructuredResultBytes = 1_048_576

    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int(exactly: number)
    }

    static func encode(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw MCPConnectionError.toolFailed("The result could not be encoded as JSON.")
        }
        return text
    }
}
