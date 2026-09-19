import Foundation

enum CommandTranscriptDelivery: Equatable {
    case dictation
    case command(String)
    case empty
    case failure(String)

    static func decide(
        event: TranscriptEvent, commandMode: Bool,
        replacements: [PhraseReplacement], bundleID: String
    ) -> Self {
        guard commandMode else { return .dictation }
        if event.isPartial {
            let detail = event.message.map { " \($0)" } ?? ""
            return .failure("The command transcript was incomplete. Please try again.\(detail)")
        }
        let raw = event.text ?? ""
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }
        let corrected = TranscriptTextProcessor.replacePhrases(raw, rules: replacements, bundleID: bundleID)
        return .command(corrected)
    }
}
