import Foundation

public enum TextAnalysis {
    /// The word the user just finished typing: letters followed by exactly one
    /// separator at the end of `text`. Names, acronyms and anything with
    /// digits are skipped since spell checkers misjudge those.
    public static func justCompletedWord(in text: String) -> (word: String, separator: Character)? {
        guard let separator = text.last, separator == " " || ",.!?;:".contains(separator) else { return nil }
        let body = text.dropLast()
        var word = ""
        for character in body.reversed() {
            if character.isLetter || character == "'" || character == "’" {
                word.append(character)
            } else if character.isWhitespace || "(\"“".contains(character) {
                break
            } else {
                return nil
            }
        }
        word = String(word.reversed())
        guard word.count >= 3, word.dropFirst().allSatisfy(\.isLowercase) else { return nil }
        return (word, separator)
    }

    /// A selection worth offering alternatives for: one word, no line breaks.
    public static func isSingleWord(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return (2...30).contains(trimmed.count) && trimmed.allSatisfy { $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" }
    }
}
