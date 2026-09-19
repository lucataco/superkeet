import Foundation

struct ActionCandidate: Equatable, Sendable {
    let id: String
    let description: String
    let tool: ActionToolSpec?
    let argumentsJSON: String
    let captureID: String?

    static let reserved: [ActionCandidate] = [
        .init(id: "reobserve", description: "Obtain a fresh observation because the current observation is incomplete or loading.", tool: nil, argumentsJSON: "{}", captureID: nil),
        .init(id: "abstain", description: "Do not act because no supplied action matches the planner instruction.", tool: nil, argumentsJSON: "{}", captureID: nil)
    ]
}

enum BoundedChoiceOutcome: String, Codable, Sendable {
    case verified, refuted, unknown, abstained
    case budgetExhausted = "budget_exhausted"
}

enum ActionChoiceError: LocalizedError, Equatable {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let reason): return "The bounded action was rejected: \(reason)."
        }
    }
}

struct ChoiceRequest: Codable, Equatable, Sendable {
    static let schemaName = "cua.jev_choice_request_v1"
    static let maximumBytes = 65_536

    struct Candidate: Codable, Equatable, Sendable {
        let id: String
        let description: String
    }

    struct History: Codable, Equatable, Sendable {
        let selectedID: String?
        let outcome: String?
        enum CodingKeys: String, CodingKey {
            case selectedID = "selected_id"
            case outcome
        }
    }

    struct Region: Codable, Equatable, Sendable {
        struct Bounds: Codable, Equatable, Sendable {
            let x: Int
            let y: Int
            let width: Int
            let height: Int
        }
        let id: String
        let kind: String
        let bounds: Bounds
        let text: String?
        let label: String?
        let confidence: Double
        let interactive: Bool
    }

    var schema = schemaName
    let goal: String
    let captureID: String
    let regions: [Region]
    let history: [History]
    let candidates: [Candidate]

    enum CodingKeys: String, CodingKey {
        case schema, goal, regions, history, candidates
        case captureID = "capture_id"
    }

    func encoded() throws -> Data {
        try validate()
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumBytes else { throw ActionChoiceError.invalid("request exceeds 64 KB") }
        return data
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw ActionChoiceError.invalid("request exceeds 64 KB") }
        let object = try JSONSerialization.jsonObject(with: data)
        let root = try ChoiceWire.object(object, required: ["schema", "goal", "capture_id", "regions", "history", "candidates"])
        for value in root["candidates"] as? [Any] ?? [] {
            _ = try ChoiceWire.object(value, required: ["id", "description"])
        }
        for value in root["history"] as? [Any] ?? [] {
            let item = try ChoiceWire.object(value, required: [], optional: ["selected_id", "outcome"])
            guard item.values.allSatisfy({ $0 is String }) else {
                throw ActionChoiceError.invalid("history values must be strings")
            }
        }
        for value in root["regions"] as? [Any] ?? [] {
            let region = try ChoiceWire.object(
                value, required: ["id", "kind", "bounds", "confidence", "interactive"], optional: ["text", "label"]
            )
            _ = try ChoiceWire.object(region["bounds"] as Any, required: ["x", "y", "width", "height"])
        }
        let request = try JSONDecoder().decode(Self.self, from: data)
        try request.validate()
        return request
    }

    func validate() throws {
        guard schema == Self.schemaName else { throw ActionChoiceError.invalid("unsupported request schema") }
        try ChoiceWire.string(goal, limit: 4_000)
        try ChoiceWire.string(captureID, limit: 256)
        guard (2...32).contains(candidates.count), regions.count <= 100, history.count <= 16 else {
            throw ActionChoiceError.invalid("collection limit exceeded")
        }
        let ids = Set(candidates.map(\.id))
        guard ids.count == candidates.count, ids.isSuperset(of: ["reobserve", "abstain"]) else {
            throw ActionChoiceError.invalid("duplicate or missing reserved candidate IDs")
        }
        for candidate in candidates {
            try ChoiceWire.identifier(candidate.id)
            try ChoiceWire.string(candidate.description, limit: 1_000)
        }
        for item in history {
            guard item.selectedID != nil || item.outcome != nil else { throw ActionChoiceError.invalid("empty history item") }
            if let id = item.selectedID { try ChoiceWire.identifier(id) }
            if let outcome = item.outcome { try ChoiceWire.string(outcome, limit: 128) }
        }
        guard Set(regions.map(\.id)).count == regions.count else { throw ActionChoiceError.invalid("duplicate region IDs") }
        for region in regions {
            try ChoiceWire.string(region.id, limit: 256)
            if let text = region.text { try ChoiceWire.string(text, limit: 1_000) }
            if let label = region.label { try ChoiceWire.string(label, limit: 1_000) }
            guard (region.kind == "text" && region.text != nil) || (region.kind == "icon" && region.label != nil),
                  region.bounds.x >= 0, region.bounds.y >= 0, region.bounds.width > 0, region.bounds.height > 0,
                  region.confidence.isFinite, (0...1).contains(region.confidence) else {
                throw ActionChoiceError.invalid("invalid visual region")
            }
        }
    }
}

struct ChoiceResponse: Codable, Equatable, Sendable {
    static let schemaName = "cua.jev_choice_v1"
    var schema = schemaName
    let selectedID: String
    let model: String?
    let confidence: Double
    let probabilities: [String: Double]

    enum CodingKeys: String, CodingKey {
        case schema, model, confidence, probabilities
        case selectedID = "selected_id"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(selectedID, forKey: .selectedID)
        try container.encode(model, forKey: .model)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(probabilities, forKey: .probabilities)
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= ChoiceRequest.maximumBytes else { throw ActionChoiceError.invalid("response exceeds 64 KB") }
        _ = try ChoiceWire.object(
            JSONSerialization.jsonObject(with: data), required: ["schema", "selected_id", "model", "confidence", "probabilities"]
        )
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func validatedCandidate(in table: [ActionCandidate], currentCaptureID: String) throws -> ActionCandidate {
        let ids = Set(table.map(\.id))
        guard schema == Self.schemaName, ids.count == table.count, (2...32).contains(table.count),
              ids.isSuperset(of: ["reobserve", "abstain"]), ids == Set(probabilities.keys),
              confidence.isFinite, (0...1).contains(confidence),
              probabilities.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              abs(probabilities.values.reduce(0, +) - 1) <= 0.001 else {
            throw ActionChoiceError.invalid("malformed response or candidate table")
        }
        try ChoiceWire.identifier(selectedID)
        for item in table {
            try ChoiceWire.identifier(item.id)
            let reserved = item.id == "reobserve" || item.id == "abstain"
            guard reserved == (item.tool == nil), !reserved || item.argumentsJSON == "{}" else {
                throw ActionChoiceError.invalid("invalid reserved action")
            }
        }
        guard let candidate = table.first(where: { $0.id == selectedID }) else {
            throw ActionChoiceError.invalid("unknown candidate ID")
        }
        if let capture = candidate.captureID, capture != currentCaptureID {
            throw ActionChoiceError.invalid("stale capture")
        }
        return candidate
    }
}

private enum ChoiceWire {
    static func object(_ value: Any, required: Set<String>, optional: Set<String> = []) throws -> [String: Any] {
        guard let object = value as? [String: Any], required.isSubset(of: Set(object.keys)),
              Set(object.keys).isSubset(of: required.union(optional)) else {
            throw ActionChoiceError.invalid("unsupported or missing fields")
        }
        return object
    }

    static func string(_ value: String, limit: Int) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.unicodeScalars.count <= limit else {
            throw ActionChoiceError.invalid("empty or oversized string")
        }
    }

    static func identifier(_ value: String) throws {
        guard value.range(of: "\\A[A-Za-z0-9][A-Za-z0-9._:-]{0,63}\\z", options: .regularExpression) != nil else {
            throw ActionChoiceError.invalid("malformed candidate ID")
        }
    }
}
