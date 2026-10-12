import Foundation

/// Decides whether a completion should be requested for the current caret position.
public struct CompletionPolicy: Equatable {
    /// Minimum number of non-whitespace characters before the caret.
    public var minimumContextLength: Int
    /// Suggest even when there is text after the caret on the same line.
    public var allowMidLine: Bool

    public init(minimumContextLength: Int = 3, allowMidLine: Bool = false) {
        self.minimumContextLength = minimumContextLength
        self.allowMidLine = allowMidLine
    }

    public func shouldComplete(before: String, after: String, hasSelection: Bool) -> Bool {
        if hasSelection { return false }
        let context = before.unicodeScalars.lazy
            .filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            .prefix(minimumContextLength)
        if context.count < minimumContextLength { return false }
        if allowMidLine { return true }
        let restOfLine = after.prefix { !$0.isNewline }
        return restOfLine.allSatisfy(\.isWhitespace)
    }
}
