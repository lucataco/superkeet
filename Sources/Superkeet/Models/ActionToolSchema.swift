import Foundation
import CryptoKit

enum ActionToolSchema {
    static let toolDescriptionLimit = 140
    static let propertyDescriptionLimit = 90

    static func description(for spec: ActionToolSpec) -> String {
        clipped(spec.description.isEmpty ? spec.displayName : spec.description, limit: toolDescriptionLimit)
    }

    static func clipped(_ text: String, limit: Int) -> String {
        String(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(limit))
    }

    static func namespace(for spec: ActionToolSpec) -> String { "\(spec.serverName)/\(spec.toolName)" }

    static func name(toolName: String, path: [String]) -> String {
        let identity = ([toolName] + path).map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        let hash = SHA256.hash(data: Data(identity.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return "s\(hash)"
    }

    static func projected(_ json: String, toolName: String) -> [String: Any]? {
        guard let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return nil }
        return project(root, toolName: toolName)
    }

    static func project(
        _ object: [String: Any], toolName: String, path: [String] = [], isProperty: Bool = false
    ) -> [String: Any]? {
        guard path.count < 64, let types = types(in: object) else { return nil }
        let type = types.first { $0 != "null" } ?? "null"
        var result: [String: Any] = ["type": types.count == 1 ? type as Any : types]
        if isProperty, let description = object["description"] as? String, !description.isEmpty {
            result["description"] = clipped(description, limit: propertyDescriptionLimit)
        }
        if let values = object["enum"] as? [Any], !values.isEmpty,
           values.allSatisfy({ $0 is String || $0 is NSNull }) {
            let choices = types.contains("string") ? values.compactMap { $0 as? String } : []
            let allowsNull = values.contains { $0 is NSNull } && (types.contains("null") || object["type"] == nil)
            guard !choices.isEmpty || allowsNull else { return nil }
            if choices.isEmpty {
                result["type"] = "null"
                return result
            }
            result["type"] = allowsNull ? ["string", "null"] as Any : "string"
            result["enum"] = choices
            result["title"] = name(toolName: toolName, path: path)
            return result
        }
        switch type {
        case "object":
            let properties = object["properties"] as? [String: [String: Any]] ?? [:]
            let required = Set(object["required"] as? [String] ?? [])
            guard required.isSubset(of: Set(properties.keys)) else { return nil }
            var projected: [String: Any] = [:]
            for key in properties.keys.sorted() {
                guard let value = properties[key],
                      let property = project(value, toolName: toolName, path: path + ["properties", key], isProperty: true) else {
                    if required.contains(key) { return nil }
                    continue
                }
                projected[key] = property
            }
            result["title"] = name(toolName: toolName, path: path)
            result["properties"] = projected
            result["required"] = required.sorted()
        case "array":
            let item = object["items"] as? [String: Any] ?? ["type": "string"]
            guard let projected = project(item, toolName: toolName, path: path + ["items"]) else { return nil }
            result["items"] = projected
            for key in ["minItems", "maxItems"] {
                if let bound = object[key] as? Int { result[key] = bound }
            }
        default: break
        }
        return result
    }

    static func types(in object: [String: Any]) -> [String]? {
        let supported: Set<String> = ["object", "array", "string", "integer", "number", "boolean", "null"]
        let types: [String]
        if let array = object["type"] as? [String] {
            types = Array(Set(array)).sorted()
        } else if let type = object["type"] as? String {
            types = [type]
        } else if object["type"] != nil || object["oneOf"] != nil || object["anyOf"] != nil || object["$ref"] != nil {
            return nil
        } else {
            types = [object["items"] != nil ? "array" : (object["enum"] != nil ? "string" : "object")]
        }
        guard !types.isEmpty, Set(types).isSubset(of: supported), types.filter({ $0 != "null" }).count <= 1 else { return nil }
        return types
    }

    static func estimatedTokenCost(of spec: ActionToolSpec) -> Int {
        let schemaBytes: Int
        if let projected = projected(spec.inputSchemaJSON, toolName: namespace(for: spec)),
           let data = try? JSONSerialization.data(withJSONObject: projected, options: [.sortedKeys]) {
            schemaBytes = data.count
        } else {
            schemaBytes = spec.inputSchemaJSON.utf8.count * 2
        }
        return (spec.toolName.utf8.count + description(for: spec).utf8.count + schemaBytes + 1) / 2 + 40
    }
}
