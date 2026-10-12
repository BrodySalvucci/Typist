import Foundation

/// Everything that can inform a completion.
public struct PromptInput {
    public var before: String
    public var instructions = ""
    public var appName: String?
    public var windowTitle: String?
    /// Placeholder text of the field ("Write a reply…").
    public var fieldHint: String?
    /// Text recognised on screen around the text field.
    public var screenText: String?
    public var clipboard: String?
    /// Earlier writing by the user, for style.
    public var samples: [String] = []

    public init(before: String) {
        self.before = before
    }
}

/// Builds the text fed to the language model.
///
/// Typist uses *base* (non-chat) models, so the prompt is laid out like a
/// document: a short header describing the situation, then the text before the
/// caret. The model simply continues it.
public struct PromptBuilder {
    /// Maximum number of characters of text-before-caret to keep.
    public var windowLength: Int
    /// The window start only moves in steps of this many characters. Keeping the
    /// start stable between keystrokes lets the engine reuse its KV cache
    /// instead of re-evaluating the whole prompt on every key press.
    public var windowStep: Int
    public var maxContextLength = 1200
    public var maxSampleLength = 400

    public init(windowLength: Int = 3000, windowStep: Int = 1000) {
        precondition(windowLength > 0 && windowStep > 0)
        self.windowLength = windowLength
        self.windowStep = windowStep
    }

    public func build(before: String, instructions: String = "") -> String {
        var input = PromptInput(before: before)
        input.instructions = instructions
        return build(input)
    }

    public func build(_ input: PromptInput) -> String {
        var sections: [String] = []

        let instructions = input.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instructions.isEmpty {
            sections.append("About the author:\n" + instructions)
        }
        if !input.samples.isEmpty {
            let samples = input.samples.map { "- " + clip($0, to: maxSampleLength).replacingOccurrences(of: "\n", with: " ") }
            sections.append("Earlier writing by the author:\n" + samples.joined(separator: "\n"))
        }
        if let screen = cleaned(input.screenText) {
            sections.append("Visible on screen:\n" + clip(screen, to: maxContextLength))
        }
        if let clipboard = cleaned(input.clipboard) {
            sections.append("Clipboard:\n" + clip(clipboard, to: maxContextLength / 2))
        }
        var location: [String] = []
        if let app = cleaned(input.appName) { location.append(app) }
        if let title = cleaned(input.windowTitle), title != input.appName { location.append(clip(title, to: 120)) }
        if let hint = cleaned(input.fieldHint) { location.append("“" + clip(hint, to: 80) + "”") }
        if !location.isEmpty {
            sections.append("The author is now writing in " + location.joined(separator: " — ") + ":")
        }

        // A trailing space would make the model start mid-token; it is cheaper
        // to drop it here and trim the leading space off the output.
        var body = window(of: input.before)
        while body.last == " " || body.last == "\t" { body.removeLast() }

        return sections.isEmpty ? body : sections.joined(separator: "\n\n") + "\n\n" + body
    }

    /// The trailing part of `text`, at most `windowLength + windowStep` long,
    /// starting at a multiple of `windowStep`.
    func window(of text: String) -> String {
        let count = text.count
        guard count > windowLength else { return text }
        let overflow = count - windowLength
        let start = (overflow / windowStep) * windowStep
        return String(text.dropFirst(start))
    }

    private func cleaned(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func clip(_ text: String, to length: Int) -> String {
        text.count > length ? String(text.prefix(length)) + "…" : text
    }
}
