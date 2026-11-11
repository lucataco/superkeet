import Foundation
import os.log

#if canImport(FoundationModels)
import FoundationModels

private let routerLog = Logger(subsystem: "com.superkeet.app", category: "IntentRouter")

/// Reads a clause with the on-device model in one constrained generation: the kind is one of
/// `RoutedIntent.Kind` by construction, and there is no tool loop. The planner's tool-calling
/// loop took 1.5 to 3 s for the same clauses and chose a wrong tool for two in six.
@available(macOS 26.0, *)
final class FoundationModelIntentRouter: IntentRouting {
    static let instructions: String = {
        let kinds = RoutedIntent.Kind.allCases.map { "- \($0.rawValue): \($0.meaning)" }.joined(separator: "\n")
        let arguments = RoutedIntent.Kind.allCases.compactMap { kind in
            kind.argumentMeaning.map { "- \(kind.rawValue): \($0)" }
        }.joined(separator: "\n")
        return """
        You read one spoken instruction to a Mac and say what it asks for. Speech recognition wrote it down, so it can hold filler words and a misheard word.

        kind is one of:
        \(kinds)

        argument is empty except for:
        \(arguments)

        Copy the argument from the instruction word for word. Never correct, shorten, translate or add to it, and never put a web address the speaker did not say.
        For type_text the argument is only the words to be typed, never the words that ask for it ("write down", "put in", "the title should be").
        new_item is only for a request to make a new empty thing. Replying, sending, moving, clicking, reading and questions are other.

        Examples:
        "could you pull up the weather app for me" -> open_app, "weather"
        "let me see my photos" -> open_app, "photos"
        "take me to wikipedia" -> open_website, "wikipedia"
        "look up how tall the eiffel tower is" -> web_search, "how tall the eiffel tower is"
        "google the capital of peru" -> web_search, "the capital of peru"
        "I want another window" -> new_item, ""
        "add the line see you at noon" -> type_text, "see you at noon"
        "write down pick up the kids at four" -> type_text, "pick up the kids at four"
        "the subject should say lunch on friday" -> type_text, "lunch on friday"
        "in this message let's make the first line say thanks again" -> type_text, "thanks again"
        "go back one step" -> undo, ""
        "bring that change back" -> redo, ""
        "answer the last message from lee and say yes" -> other, ""
        "press the blue button" -> other, ""
        "how many unread messages do I have" -> other, ""
        "okay that looks right" -> nothing, ""
        "wait, one second" -> nothing, ""
        """
    }()

    static let schema: GenerationSchema? = {
        let kind = DynamicGenerationSchema(name: "IntentKind", anyOf: RoutedIntent.Kind.allCases.map(\.rawValue))
        let root = DynamicGenerationSchema(name: "SpokenIntent", properties: [
            .init(name: "kind", description: "What the instruction asks for.", schema: kind),
            .init(name: "argument", description: "The words the instruction is about, copied from it, or empty.",
                  schema: DynamicGenerationSchema(type: String.self))
        ])
        return try? GenerationSchema(root: root, dependencies: [])
    }()

    /// The same clause must read the same way every time.
    private static let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 80)
    private static var warmSession: LanguageModelSession?

    static func prompt(for clause: String, currentApp: String?) -> String {
        let spoken = clause.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "'")
        let app = currentApp.map { "The \($0) app is in front.\n" } ?? ""
        return "\(app)Instruction: \"\(spoken)\""
    }

    static func intent(fromJSON json: String) -> RoutedIntent? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let raw = object["kind"] as? String, let kind = RoutedIntent.Kind(rawValue: raw) else { return nil }
        return RoutedIntent(kind: kind, argument: object["argument"] as? String)
    }

    func prewarm() {
        let session = LanguageModelSession(instructions: Self.instructions)
        session.prewarm()
        Self.warmSession = session
    }

    func route(_ clause: String, currentApp: String?) async -> RoutedIntent? {
        guard let schema = Self.schema else { return nil }
        let clock = ContinuousClock()
        let started = clock.now
        do {
            let session = LanguageModelSession(instructions: Self.instructions)
            let response = try await session.respond(
                to: Self.prompt(for: clause, currentApp: currentApp), schema: schema, options: Self.options
            )
            let intent = Self.intent(fromJSON: response.content.jsonString)
            routerLog.info("Read a clause as \(intent?.kind.rawValue ?? "nothing usable", privacy: .public) in \(clock.now - started, privacy: .public)")
            return intent
        } catch {
            routerLog.info("Could not read a clause: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

#endif
