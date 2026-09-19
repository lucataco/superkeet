import Foundation

protocol ActionChoosing: Sendable {
    func prepare() async throws
    func choose(_ request: ChoiceRequest) async throws -> ChoiceResponse
}

extension ActionChoosing {
    func prepare() async throws {}
}

struct HeuristicChooser: ActionChoosing {
    func choose(_ request: ChoiceRequest) async throws -> ChoiceResponse {
        _ = try request.encoded()
        let executable = request.candidates.filter { $0.id != "reobserve" && $0.id != "abstain" }
        let selected = executable.count == 1 ? executable[0].id : "reobserve"
        return ChoiceResponse(
            selectedID: selected, model: "heuristic", confidence: 1,
            probabilities: Dictionary(uniqueKeysWithValues: request.candidates.map { ($0.id, $0.id == selected ? 1 : 0) })
        )
    }
}
