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
        return result.trimmingCharacters(in: .whitespaces)
    }
}
