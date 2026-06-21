import Foundation

/// Removes common filler words from transcription output.
/// Uses a regex pattern that matches standalone filler words at word boundaries.
enum FillerWordCleaner {
    // Pattern matches common English filler words as whole words, with optional trailing comma.
    // Note: "ugh" is intentionally excluded — it is a legitimate interjection that
    // users may want preserved in their transcription ("ugh, this is broken").
    private static let fillerPattern = "\\b(?:uh|uhh|um|umm|er|err|hmm|hmmm|ah|ahh)\\b,?\\s*"
    private static let multiSpacePattern = " {2,}"

    /// Remove filler words from the given text and clean up extra whitespace.
    static func clean(_ text: String) -> String {
        var result = text.replacingOccurrences(
            of: fillerPattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        // Collapse any double spaces left behind
        result = result.replacingOccurrences(
            of: multiSpacePattern,
            with: " ",
            options: .regularExpression
        )
        return result.trimmingCharacters(in: .whitespaces)
    }
}
