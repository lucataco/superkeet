import Foundation
import os.log

private let decisionLog = Logger(subsystem: "com.superkeet.app", category: "IntentRouter")

/// Reads a clause with a local decision model served by Ollama (`POST /v1/systemone`, Ollama
/// 0.35+), such as `clef-flash`. A decision model chooses between labels; it cannot write text.
/// So the kind is one choice, and the argument is a second choice of where in the clause it
/// starts: the words from there to the end are the speaker's own.
///
/// Nothing leaves the machine: the endpoint is the loopback address.
final class OllamaDecisionIntentRouter: IntentRouting {
    struct Configuration: Equatable, Sendable {
        var model = "clef-flash"
        var endpoint = URL(string: "http://127.0.0.1:11434/v1/systemone")
        /// Below this the model is guessing, and the clause goes to the planner instead.
        var minimumConfidence = 0.35
        var timeout: TimeInterval = 6
        /// Ollama accepts 2 to 26 options for one choice, one of which is "none".
        var maximumWords = 25
    }

    /// The part of every request that never changes. Ollama keeps the model's work on a
    /// request's leading text, so the guide goes first and the clause last: measured on an
    /// M2 Pro, 0.7 s a decision this way round against 1.7 s the other.
    static let guide: String = {
        let kinds = RoutedIntent.Kind.allCases.map { "\($0.rawValue) = \($0.meaning)" }.joined(separator: "\n")
        return """
        A voice assistant controls a Mac. Each request below is one spoken instruction, written down by speech recognition, so it can hold filler words and a misheard word.
        Labels:
        \(kinds)
        """
    }()

    private let configuration: Configuration
    private let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(configuration: Configuration = Configuration(),
         transport: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil) {
        self.configuration = configuration
        self.transport = transport ?? { try await URLSession.shared.data(for: $0) }
    }

    func prewarm() {
        Task { [self] in _ = await kind(of: "okay", currentApp: nil) }
    }

    func route(_ clause: String, currentApp: String?) async -> RoutedIntent? {
        let clock = ContinuousClock()
        let started = clock.now
        guard let kind = await kind(of: clause, currentApp: currentApp) else { return nil }
        var argument: String?
        if kind.argumentMeaning != nil {
            argument = await self.argument(of: kind, in: clause)
        }
        decisionLog.info("Read a clause as \(kind.rawValue, privacy: .public) in \(clock.now - started, privacy: .public)")
        return RoutedIntent(kind: kind, argument: argument)
    }

    private func kind(of clause: String, currentApp: String?) async -> RoutedIntent.Kind? {
        let app = currentApp.map { " The \($0) app is in front." } ?? ""
        let question = Self.choice(
            instructions: "Which label fits this spoken instruction?\(app) Instruction: \(Self.quoted(clause))",
            options: RoutedIntent.Kind.allCases.map { ($0.rawValue, nil) }
        )
        guard let answer = await ask(["kind": question])?["kind"],
              answer.confidence >= configuration.minimumConfidence else { return nil }
        return RoutedIntent.Kind(rawValue: answer.choice)
    }

    private func argument(of kind: RoutedIntent.Kind, in clause: String) async -> String? {
        guard let meaning = kind.argumentMeaning else { return nil }
        let words = Self.words(in: clause)
        guard !words.isEmpty, words.count <= configuration.maximumWords else { return nil }
        var options: [(String, String?)] = words.enumerated().map { ("w\($0.offset + 1)", String(clause[$0.element])) }
        options.append(("none", "the instruction does not say it"))
        let question = Self.choice(
            instructions: "The instruction \(Self.quoted(clause)) is a \(kind.rawValue) request. "
                + "Which numbered word is the first word of \(meaning)?",
            options: options
        )
        guard let answer = await ask(["start": question])?["start"], answer.confidence >= configuration.minimumConfidence,
              answer.choice.hasPrefix("w"), let number = Int(answer.choice.dropFirst()),
              words.indices.contains(number - 1) else { return nil }
        return Self.trimmed(String(clause[words[number - 1].lowerBound...]))
    }

    struct Answer: Equatable {
        let choice: String
        let confidence: Double
    }

    private func ask(_ questions: [String: String]) async -> [String: Answer]? {
        guard let endpoint = configuration.endpoint else { return nil }
        var request = URLRequest(url: endpoint, timeoutInterval: configuration.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.body(model: configuration.model, questions: questions).utf8)
        do {
            let (data, response) = try await transport(request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                decisionLog.info("The decision model answered \((response as? HTTPURLResponse)?.statusCode ?? 0, privacy: .public)")
                return nil
            }
            return Self.answers(in: data)
        } catch {
            decisionLog.info("The decision model is not reachable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Wire format

    /// Options are written in the order given. A dictionary would shuffle them on every launch,
    /// and the model reads them in order.
    static func choice(instructions: String, options: [(String, String?)]) -> String {
        let criteria = options.map { "\(quoted($0.0)):\($0.1.map(quoted) ?? "null")" }.joined(separator: ",")
        return "{\"type\":\"choice\",\"instructions\":\(quoted(instructions)),\"criteria\":{\(criteria)}}"
    }

    static func body(model: String, questions: [String: String]) -> String {
        let entries = questions.keys.sorted().map { "\(quoted($0)):\(questions[$0] ?? "null")" }.joined(separator: ",")
        return "{\"model\":\(quoted(model)),\"keep_alive\":\"30m\",\"state\":\(quoted(guide)),\"questions\":{\(entries)}}"
    }

    static func answers(in data: Data) -> [String: Answer]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = object["answers"] as? [String: [String: Any]] else { return nil }
        var result: [String: Answer] = [:]
        for (name, answer) in answers {
            guard let choice = answer["choice"] as? String else { continue }
            result[name] = Answer(choice: choice, confidence: (answer["confidence"] as? Double) ?? 0)
        }
        return result
    }

    static func quoted(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]),
              let json = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(json.dropFirst().dropLast())
    }

    /// Runs of non-space characters, with their place in the clause.
    static func words(in clause: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        for index in clause.indices {
            if clause[index].isWhitespace {
                if let begin = start { ranges.append(begin..<index) }
                start = nil
            } else if start == nil {
                start = index
            }
        }
        if let begin = start { ranges.append(begin..<clause.endIndex) }
        return ranges
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;:!?")))
    }
}
