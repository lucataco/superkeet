import XCTest
@testable import Superkeet

@MainActor
final class OllamaDecisionIntentRouterTests: XCTestCase {
    /// Answers each request from a script and keeps what was asked.
    final class Transport: @unchecked Sendable {
        var replies: [String]
        var status = 200
        private(set) var bodies: [[String: Any]] = []
        private(set) var urls: [URL?] = []

        init(_ replies: [String]) { self.replies = replies }

        func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
            urls.append(request.url)
            if let body = request.httpBody, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                bodies.append(object)
            }
            let reply = replies.isEmpty ? "{}" : replies.removeFirst()
            let url = request.url ?? URL(fileURLWithPath: "/")
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) ?? URLResponse()
            return (Data(reply.utf8), response)
        }
    }

    private func answer(_ name: String, _ choice: String, confidence: Double = 0.8) -> String {
        #"{"model":"clef-flash","answers":{"\#(name)":{"type":"choice","choice":"\#(choice)","confidence":\#(confidence)}}}"#
    }

    private func router(_ transport: Transport) -> OllamaDecisionIntentRouter {
        OllamaDecisionIntentRouter(transport: { try await transport.send($0) })
    }

    func testAKindWithoutAnArgumentIsOneDecision() async {
        let transport = Transport([answer("kind", "new_item")])
        let intent = await router(transport).route("Start a fresh document.", currentApp: "TextEdit")
        XCTAssertEqual(intent, RoutedIntent(kind: .newItem))
        XCTAssertEqual(transport.bodies.count, 1)
        XCTAssertEqual(transport.urls.first??.absoluteString, "http://127.0.0.1:11434/v1/systemone", "Only the loopback address is used.")
        XCTAssertEqual(transport.bodies[0]["model"] as? String, "clef-flash")
        XCTAssertEqual(transport.bodies[0]["state"] as? String, OllamaDecisionIntentRouter.guide, "The unchanging guide leads, so Ollama reuses its work.")
    }

    func testTheArgumentIsTheSpeakersWordsFromTheChosenWordOn() async {
        let transport = Transport([answer("kind", "type_text"), answer("start", "w5")])
        let intent = await router(transport).route("The heading should be quarterly review.", currentApp: "TextEdit")
        XCTAssertEqual(intent, RoutedIntent(kind: .typeText, argument: "quarterly review"))
        XCTAssertEqual(transport.bodies.count, 2)
        let question = ((transport.bodies[1]["questions"] as? [String: Any])?["start"] as? [String: Any])
        let criteria = question?["criteria"] as? [String: Any]
        XCTAssertEqual(criteria?["w5"] as? String, "quarterly")
        XCTAssertEqual(criteria?.count, 7, "Six words and “none”.")
    }

    func testOptionsKeepTheirOrderOnTheWire() {
        let question = OllamaDecisionIntentRouter.choice(instructions: "Pick \"one\".", options: [("b", nil), ("a", "first\nletter")])
        XCTAssertEqual(question, #"{"type":"choice","instructions":"Pick \"one\".","criteria":{"b":null,"a":"first\nletter"}}"#)
        let kinds = OllamaDecisionIntentRouter.choice(instructions: "x", options: RoutedIntent.Kind.allCases.map { ($0.rawValue, nil) })
        XCTAssertLessThan(try XCTUnwrap(kinds.range(of: "open_app")).lowerBound, try XCTUnwrap(kinds.range(of: "nothing")).lowerBound)
    }

    func testAGuessIsNotAReading() async {
        let unsure = Transport([answer("kind", "close", confidence: 0.2)])
        let unsureIntent = await router(unsure).route("put that back", currentApp: nil)
        XCTAssertNil(unsureIntent, "Below the confidence floor the planner takes the clause.")

        let noStart = Transport([answer("kind", "web_search"), answer("start", "none")])
        let noStartIntent = await router(noStart).route("look it up", currentApp: nil)
        XCTAssertEqual(noStartIntent, RoutedIntent(kind: .webSearch), "A kind with no words resolves to nothing runnable.")
    }

    func testAnUnreachableOrFailingServerReadsNothing() async {
        let failing = Transport(["{\"error\":\"model not found\"}"])
        failing.status = 404
        let failed = await router(failing).route("open the calculator", currentApp: nil)
        XCTAssertNil(failed)

        let offline = OllamaDecisionIntentRouter(transport: { _ in throw URLError(.cannotConnectToHost) })
        let unreachable = await offline.route("open the calculator", currentApp: nil)
        XCTAssertNil(unreachable)
    }

    func testAClauseTooLongToPointIntoHasNoArgument() async {
        let long = Array(repeating: "word", count: 30).joined(separator: " ")
        let transport = Transport([answer("kind", "type_text")])
        let intent = await router(transport).route(long, currentApp: "Notes")
        XCTAssertEqual(intent, RoutedIntent(kind: .typeText))
        XCTAssertEqual(transport.bodies.count, 1, "Ollama takes at most 26 options for one choice.")
    }
}
