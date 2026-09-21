import Foundation

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, *)
enum MCPGenerationSchemaConverter {
    static func schema(fromJSON json: String, toolName: String = "parameters") -> GenerationSchema? {
        guard let projected = ActionToolSchema.projected(json, toolName: toolName),
              let root = convert(projected, toolName: toolName, path: []) else { return nil }
        return try? GenerationSchema(root: root, dependencies: [])
    }

    private static func convert(_ object: [String: Any], toolName: String, path: [String]) -> DynamicGenerationSchema? {
        guard let types = ActionToolSchema.types(in: object) else { return nil }
        let type = types.first { $0 != "null" } ?? "null"
        let schema: DynamicGenerationSchema
        if let choices = object["enum"] as? [String], !choices.isEmpty {
            schema = DynamicGenerationSchema(name: ActionToolSchema.name(toolName: toolName, path: path), anyOf: choices)
        } else {
            switch type {
            case "array":
                guard let items = object["items"] as? [String: Any],
                      let item = convert(items, toolName: toolName, path: path + ["items"]) else { return nil }
                schema = DynamicGenerationSchema(arrayOf: item, minimumElements: object["minItems"] as? Int,
                                                 maximumElements: object["maxItems"] as? Int)
            case "object":
                guard let objectSchema = objectSchema(object, toolName: toolName, path: path) else { return nil }
                schema = objectSchema
            case "string": schema = DynamicGenerationSchema(type: String.self)
            case "integer": schema = DynamicGenerationSchema(type: Int.self)
            case "number": schema = DynamicGenerationSchema(type: Double.self)
            case "boolean": schema = DynamicGenerationSchema(type: Bool.self)
            case "null":
                if #available(macOS 26.4, *) { return .null }
                return nil
            default: return nil
            }
        }
        if types.contains("null"), #available(macOS 26.4, *) {
            return DynamicGenerationSchema(name: ActionToolSchema.name(toolName: toolName, path: path + ["nullable"]),
                                           anyOf: [schema, .null])
        }
        return schema
    }

    private static func objectSchema(_ object: [String: Any], toolName: String, path: [String]) -> DynamicGenerationSchema? {
        let properties = object["properties"] as? [String: [String: Any]] ?? [:]
        let required = Set(object["required"] as? [String] ?? [])
        var converted: [DynamicGenerationSchema.Property] = []
        for key in properties.keys.sorted() {
            guard let property = properties[key], let schema = convert(property, toolName: toolName, path: path + ["properties", key]) else {
                if required.contains(key) { return nil }
                continue
            }
            converted.append(DynamicGenerationSchema.Property(name: key, description: property["description"] as? String,
                                                               schema: schema, isOptional: !required.contains(key)))
        }
        return DynamicGenerationSchema(name: ActionToolSchema.name(toolName: toolName, path: path), properties: converted)
    }
}

@available(macOS 26.0, *)
struct MCPToolBridge: Tool, CustomStringConvertible {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let spec: ActionToolSpec
    let execute: @Sendable (ActionToolSpec, String) async throws -> String
    let parameters: GenerationSchema
    let description: String
    let estimatedTokenCost: Int

    init?(spec: ActionToolSpec, execute: @escaping @Sendable (ActionToolSpec, String) async throws -> String) {
        guard let schema = MCPGenerationSchemaConverter.schema(fromJSON: spec.inputSchemaJSON, toolName: ActionToolSchema.namespace(for: spec)) else {
            return nil
        }
        self.spec = spec
        self.execute = execute
        self.parameters = schema
        self.description = ActionToolSchema.description(for: spec)
        self.estimatedTokenCost = ActionLimits.estimatedTokenCost(of: spec)
    }

    var name: String { spec.toolName }

    func call(arguments: GeneratedContent) async throws -> String {
        try await execute(spec, arguments.jsonString)
    }
}
#endif
