import XCTest
@testable import Superkeet

final class ActionChoiceTests: XCTestCase {
    // Cua PR #3916, commit 201732fffd81a40818be7ce2e04269aec962bc42.
    private let fixture = #"""
    {"schema":"cua.jev_choice_request_v1","goal":"Submit the verified form.","capture_id":"capture-fixture-1",
     "regions":[{"id":"submit-text","kind":"text","bounds":{"x":300,"y":240,"width":100,"height":40},
                 "text":"Submit","confidence":0.96,"interactive":true}],"history":[],
     "candidates":[{"id":"submit-form","description":"Submit using the unique validated visual region."},
                   {"id":"reobserve","description":"Discard this decision set and obtain a fresh observation."},
                   {"id":"abstain","description":"Stop without acting if no supplied action is safe."}]}
    """#

    private func request(candidates: [ChoiceRequest.Candidate]? = nil, goal: String = "Open Calculator") -> ChoiceRequest {
        ChoiceRequest(goal: goal, captureID: "capture", regions: [], history: [], candidates: candidates ?? [
            .init(id: "launch", description: "Launch Calculator"),
            .init(id: "reobserve", description: "Observe again"),
            .init(id: "abstain", description: "Stop")
        ])
    }

    private func table(capture: String = "capture") -> [ActionCandidate] {
        let tool = ActionToolSpec(descriptor: MCPToolDescriptor(
            serverID: UUID(), serverName: "driver", name: "launch_app", title: nil,
            description: nil, risk: .mutating, inputSchemaJSON: "{}"
        ))
        return [.init(id: "launch", description: "Launch Calculator", tool: tool,
                      argumentsJSON: #"{"name":"Calculator"}"#, captureID: capture)] + ActionCandidate.reserved
    }

    private func response(selected: String = "launch") -> ChoiceResponse {
        ChoiceResponse(selectedID: selected, model: "test", confidence: 0.9,
                       probabilities: ["launch": 0.9, "reobserve": 0.05, "abstain": 0.05])
    }

    func testUpstreamRequestFixtureRoundTrip() throws {
        let original = try ChoiceRequest.decode(Data(fixture.utf8))
        XCTAssertEqual(original.candidates.first?.id, "submit-form")
        XCTAssertEqual(original.regions.first?.bounds.width, 100)
        XCTAssertEqual(try ChoiceRequest.decode(original.encoded()), original)
    }

    func testResponseRoundTripAndOriginalArguments() throws {
        let original = response()
        let decoded = try ChoiceResponse.decode(JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        let candidates = table()
        XCTAssertEqual(try decoded.validatedCandidate(in: candidates, currentCaptureID: "capture"), candidates[0])
        let noModel = ChoiceResponse(selectedID: "launch", model: nil, confidence: 0.9, probabilities: original.probabilities)
        XCTAssertEqual(try ChoiceResponse.decode(JSONEncoder().encode(noModel)), noModel)
    }

    func testCandidateCountAndReservedIDs() throws {
        let reserved = Array(request().candidates.suffix(2))
        XCTAssertNoThrow(try request(candidates: reserved).encoded())
        XCTAssertThrowsError(try request(candidates: Array(reserved.prefix(1))).encoded())
        let maximum = reserved + (0..<30).map { ChoiceRequest.Candidate(id: "item\($0)", description: "Item \($0)") }
        XCTAssertNoThrow(try request(candidates: maximum).encoded())
        XCTAssertThrowsError(try request(candidates: maximum + [.init(id: "extra", description: "Extra")]).encoded())
        XCTAssertThrowsError(try request(candidates: [.init(id: "one", description: "One"), .init(id: "two", description: "Two")]).encoded())
        XCTAssertThrowsError(try request(candidates: reserved + reserved).encoded())
    }

    func testCharacterAndByteLimits() throws {
        XCTAssertNoThrow(try request(goal: String(repeating: "é", count: 4_000)).encoded())
        XCTAssertThrowsError(try request(goal: String(repeating: "a", count: 4_001)).encoded())
        XCTAssertThrowsError(try ChoiceRequest.decode(Data(repeating: 32, count: 65_537)))
        let large = (0..<30).map { ChoiceRequest.Candidate(id: "item\($0)", description: String(repeating: "🌍", count: 1_000)) }
        XCTAssertThrowsError(try request(candidates: large + Array(request().candidates.suffix(2))).encoded())
    }

    func testWireRejectsExecutableFieldsAndEnvironment() throws {
        for (old, new) in [
            (#""goal":"Submit the verified form.""#, #""goal":"Submit the verified form.","environment":{}"#),
            (#""id":"submit-form""#, #""id":"submit-form","tool":"click""#),
            (#""x":300"#, #""x":300,"capture_id":"other""#)
        ] {
            XCTAssertThrowsError(try ChoiceRequest.decode(Data(fixture.replacingOccurrences(of: old, with: new).utf8)))
        }
    }

    func testMalformedRegionsAndHistoryFailClosed() {
        for (old, new) in [
            (#""confidence":0.96"#, #""confidence":1.1"#),
            (#""width":100"#, #""width":0"#),
            (#""x":300"#, #""x":true"#),
            (#""kind":"text""#, #""kind":"unsupported""#),
            (#""history":[]"#, #""history":[{}]"#),
            (#""history":[]"#, #""history":[{"selected_id":null,"outcome":"unknown"}]"#),
            (#""history":[]"#, #""history":[{"selected_id":"launch","arguments":{}}]"#)
        ] {
            XCTAssertThrowsError(try ChoiceRequest.decode(Data(fixture.replacingOccurrences(of: old, with: new).utf8)))
        }
    }

    func testRegionAndHistoryLimits() throws {
        let fixture = try ChoiceRequest.decode(Data(fixture.utf8))
        let region = try XCTUnwrap(fixture.regions.first)
        let regions = (0..<100).map { index in
            ChoiceRequest.Region(id: "region\(index)", kind: region.kind, bounds: region.bounds,
                                 text: region.text, label: nil, confidence: 0.9, interactive: true)
        }
        let history = Array(repeating: ChoiceRequest.History(selectedID: "reobserve", outcome: "unknown"), count: 16)
        func make(_ regions: [ChoiceRequest.Region], _ history: [ChoiceRequest.History]) -> ChoiceRequest {
            ChoiceRequest(goal: "Submit", captureID: "capture", regions: regions, history: history, candidates: fixture.candidates)
        }
        XCTAssertNoThrow(try make(regions, history).encoded())
        XCTAssertThrowsError(try make(regions + [region], history).encoded())
        XCTAssertThrowsError(try make(regions, history + history).encoded())
        XCTAssertThrowsError(try make([region, region], []).encoded())
    }

    func testMalformedIDsAndReservedMutationsFailClosed() {
        for id in ["bad id", "launch\n", "", String(repeating: "a", count: 65)] {
            XCTAssertThrowsError(try request(candidates: Array(request().candidates.suffix(2)) + [.init(id: id, description: "Bad")]).encoded())
        }
        let original = table()
        let bad = ActionCandidate(id: "abstain", description: "Bad", tool: original[0].tool,
                                  argumentsJSON: "{}", captureID: nil)
        XCTAssertThrowsError(try response(selected: "abstain").validatedCandidate(in: [original[0], original[1], bad], currentCaptureID: "capture"))
    }

    func testUnknownDuplicateAndStalePicksFailClosed() {
        let candidates = table()
        XCTAssertThrowsError(try response(selected: "invented").validatedCandidate(in: candidates, currentCaptureID: "capture"))
        XCTAssertThrowsError(try response().validatedCandidate(in: candidates + [candidates[0]], currentCaptureID: "capture"))
        XCTAssertThrowsError(try response().validatedCandidate(in: candidates, currentCaptureID: "new-capture"))
    }

    func testInvalidConfidenceAndProbabilityVectorFailClosed() {
        for confidence in [Double.nan, .infinity, -0.1, 1.1] {
            let invalid = ChoiceResponse(selectedID: "launch", model: nil, confidence: confidence, probabilities: response().probabilities)
            XCTAssertThrowsError(try invalid.validatedCandidate(in: table(), currentCaptureID: "capture"))
        }
        for probabilities in [["launch": 1.0], ["launch": 1, "reobserve": 1, "abstain": 1],
                              ["launch": Double.nan, "reobserve": 0, "abstain": 0]] {
            let invalid = ChoiceResponse(selectedID: "launch", model: nil, confidence: 1, probabilities: probabilities)
            XCTAssertThrowsError(try invalid.validatedCandidate(in: table(), currentCaptureID: "capture"))
        }
    }

    func testHeuristicSelectsOnlyUniqueExecutableCandidate() async throws {
        let chooser = HeuristicChooser()
        let unique = try await chooser.choose(request())
        XCTAssertEqual(unique.selectedID, "launch")
        let ambiguous = try await chooser.choose(request(candidates: request().candidates + [.init(id: "other", description: "Other")]))
        XCTAssertEqual(ambiguous.selectedID, "reobserve")
        let empty = try await chooser.choose(request(candidates: Array(request().candidates.suffix(2))))
        XCTAssertEqual(empty.selectedID, "reobserve")
    }
}
