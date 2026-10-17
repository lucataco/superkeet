import Foundation

struct LossyDecodable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

enum LossyDecoding {
    static func array<Value: Decodable>(_ type: Value.Type, from data: Data, decoder: JSONDecoder) throws -> (values: [Value], dropped: Int) {
        let items = try decoder.decode([LossyDecodable<Value>].self, from: data)
        let values = items.compactMap(\.value)
        return (values, items.count - values.count)
    }

    static func dictionary<Value: Decodable>(_ type: Value.Type, from data: Data, decoder: JSONDecoder) throws -> (values: [String: Value], dropped: Int) {
        let items = try decoder.decode([String: LossyDecodable<Value>].self, from: data)
        let values = items.compactMapValues(\.value)
        return (values, items.count - values.count)
    }
}
