import Foundation

enum FillerWordCleaner {
    private static let fillerPattern = "\\b(?:uh|uhh|um|umm)\\b,?[^\\S\\r\\n]*"
    private static let multiSpacePattern = " {2,}"

    static func clean(_ text: String) -> String {
        var result = text.replacingOccurrences(
            of: fillerPattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        result = result.replacingOccurrences(
            of: multiSpacePattern,
            with: " ",
            options: .regularExpression
        )
        result = result.trimmingCharacters(in: .whitespaces)
        if removedFiller(from: text), result.allSatisfy({ trailingPunctuation.contains($0) }) { return "" }
        return result
    }

    private static let trailingPunctuation: Set<Character> = [".", ",", "!", "?", "…", ";", ":"]

    private static func removedFiller(from text: String) -> Bool {
        text.range(of: fillerPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
