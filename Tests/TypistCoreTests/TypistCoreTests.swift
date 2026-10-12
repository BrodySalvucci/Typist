import Foundation
import Testing
@testable import TypistCore

@Suite struct SuggestionTests {
    @Test func stopsAtNewlineAndLimitsWords() {
        let s = Suggestion.make(raw: " quick brown fox jumps\nover", before: "The", maxWords: 3)
        #expect(s?.remaining == " quick brown fox")
    }

    @Test func dropsLeadingWhitespaceAfterSpace() {
        #expect(Suggestion.make(raw: "  world", before: "Hello ", maxWords: 5)?.remaining == "world")
        #expect(Suggestion.make(raw: " world", before: "Hello", maxWords: 5)?.remaining == " world")
    }

    @Test func emptyOutputGivesNoSuggestion() {
        #expect(Suggestion.make(raw: "\nnext line", before: "Hi", maxWords: 5) == nil)
        #expect(Suggestion.make(raw: "   ", before: "Hi ", maxWords: 5) == nil)
        #expect(Suggestion.make(raw: "word", before: "Hi ", maxWords: 0) == nil)
    }

    @Test func truncatedDropsPartialLastWord() {
        #expect(Suggestion.make(raw: "to the sto", before: "go ", maxWords: 9, truncated: true)?.remaining == "to the")
        #expect(Suggestion.make(raw: "sto", before: "go ", maxWords: 9, truncated: true)?.remaining == "sto")
        #expect(Suggestion.make(raw: "to the ", before: "go ", maxWords: 9, truncated: true)?.remaining == "to the")
    }

    @Test func acceptWordByWord() {
        var s = Suggestion("lo there, friend")
        let first = s.acceptNextChunk()
        let second = s.acceptNextChunk()
        #expect(first == "lo")
        #expect(second == " there,")
        #expect(s.remaining == " friend")
        let rest = s.acceptAll()
        #expect(rest == " friend")
        #expect(s.isEmpty)
    }

    @Test func typingThrough() {
        var s = Suggestion(" world")
        let matched = s.consume(typed: " ") && s.consume(typed: "w")
        #expect(matched)
        #expect(s.remaining == "orld")
        let mismatch = s.consume(typed: "x")
        let empty = s.consume(typed: "")
        #expect(!mismatch && !empty)
    }
}

@Suite struct CompletionPolicyTests {
    let policy = CompletionPolicy()

    @Test func needsSomeContext() {
        #expect(!policy.shouldComplete(before: " a\n", after: "", hasSelection: false))
        #expect(policy.shouldComplete(before: "Hey", after: "", hasSelection: false))
    }

    @Test func noCompletionWithSelection() {
        #expect(!policy.shouldComplete(before: "Hello there", after: "", hasSelection: true))
    }

    @Test func midLine() {
        #expect(!policy.shouldComplete(before: "Hello", after: " world", hasSelection: false))
        #expect(policy.shouldComplete(before: "Hello", after: "  \nnext", hasSelection: false))
        let midLine = CompletionPolicy(allowMidLine: true)
        #expect(midLine.shouldComplete(before: "Hello", after: " world", hasSelection: false))
    }
}

@Suite struct PromptBuilderTests {
    @Test func shortTextIsUntouched() {
        #expect(PromptBuilder().build(before: "Hello") == "Hello")
        #expect(PromptBuilder().build(before: "Hello", instructions: " Be brief. \n") == "About the author:\nBe brief.\n\nHello")
    }

    @Test func windowStartIsStableBetweenKeystrokes() {
        let builder = PromptBuilder(windowLength: 100, windowStep: 50)
        let text = String(repeating: "abcdefghij", count: 13) // 130 chars
        let a = builder.build(before: text)
        let b = builder.build(before: text + "x")
        #expect(a.count == 130)
        #expect(b == a + "x")
        // Crossing a step boundary shifts the window by exactly one step.
        let c = builder.build(before: text + String(repeating: "y", count: 20))
        #expect(c.count == 100)
        #expect((text + String(repeating: "y", count: 20)).hasSuffix(c))
    }
}

@Suite struct AcceptOptionsTests {
    @Test func trailingSpaceAndPunctuation() {
        let s = Suggestion(" there, friend.")
        #expect(s.nextChunk() == " there,")
        #expect(s.nextChunk(.init(includeTrailingSpace: true)) == " there, ")
        #expect(s.nextChunk(.init(includeAttachedPunctuation: false)) == " there")
        #expect(Suggestion(", friend").nextChunk(.init(includeAttachedPunctuation: false)) == ",")
        #expect(Suggestion(" don't stop").nextChunk(.init(includeAttachedPunctuation: false)) == " don't")
    }
}

@Suite struct PromptContextTests {
    @Test func contextSectionsComeBeforeTheText() {
        var input = PromptInput(before: "Hi Sam, ")
        input.instructions = "I'm Alex."
        input.appName = "Mail"
        input.windowTitle = "Re: Invoice"
        input.clipboard = "INV-42"
        let prompt = PromptBuilder().build(input)
        #expect(prompt.hasPrefix("About the author:\nI'm Alex."))
        #expect(prompt.contains("Clipboard:\nINV-42"))
        #expect(prompt.contains("writing in Mail — Re: Invoice:"))
        // Trailing space is dropped so the model starts on a token boundary.
        #expect(prompt.hasSuffix("\n\nHi Sam,"))
    }
}

@Suite struct PreferencesTests {
    @Test func missingKeysGetDefaults() {
        let stored = #"{"maxWords": 16, "apps": {"com.example": {"tabDisabled": true}}}"#
        let prefs = Preferences.decode(from: Data(stored.utf8))
        #expect(prefs.maxWords == 16)
        #expect(prefs.enabled)
        #expect(prefs.acceptWordShortcut == .tab)
        #expect(prefs.app("com.example").tabDisabled)
        #expect(prefs.app("com.example").fontScale == 1.0)
        #expect(Preferences.decode(from: prefs.encoded()) == prefs)
    }

    @Test func enablement() {
        var prefs = Preferences()
        prefs.enabledByDefault = false
        prefs.apps["a"] = AppOverride()
        prefs.apps["a"]?.enabled = .on
        prefs.domains["example.com"] = DomainOverride()
        prefs.domains["example.com"]?.enabled = .off
        #expect(prefs.isEnabled(inApp: "a"))
        #expect(!prefs.isEnabled(inApp: "b"))
        #expect(!prefs.isEnabled(onDomain: "example.com"))
        #expect(prefs.isEnabled(onDomain: nil))
    }
}

@Suite struct EmojiTests {
    @Test func queryNeedsWordStartingColon() {
        #expect(EmojiCatalog.query(in: "so funny :jo") == "jo")
        #expect(EmojiCatalog.query(in: ":thumbsup") == "thumbsup")
        #expect(EmojiCatalog.query(in: "at 10:30") == nil)
        #expect(EmojiCatalog.query(in: "https://ex") == nil)
        #expect(EmojiCatalog.query(in: "a :j") == nil)
        #expect(EmojiCatalog.query(in: "no colon") == nil)
    }

    @Test func searchAndSkinTone() {
        #expect(EmojiCatalog.search("joy").first?.character == "😂")
        #expect(EmojiCatalog.search("thumbsu").first?.character == "👍")
        #expect(EmojiCatalog.search("zzzzzz").isEmpty)
        let thumbs = EmojiCatalog.search("thumbsup")[0]
        #expect(EmojiCatalog.render(thumbs, skinTone: 3) == "👍🏽")
        #expect(EmojiCatalog.render(thumbs, skinTone: 0) == "👍")
        #expect(EmojiCatalog.render(EmojiCatalog.search("joy")[0], skinTone: 3) == "😂")
        #expect(EmojiCatalog.all.count > 250)
    }
}

@Suite struct StatsAndSamplesTests {
    @Test func statsCountWordsPerDay() {
        var stats = UsageStats()
        stats.recordShown()
        stats.recordAccepted(" quick brown", firstOfSuggestion: true)
        stats.recordAccepted(" fox", firstOfSuggestion: false)
        #expect(stats.day().shown == 1)
        #expect(stats.day().accepted == 1)
        #expect(stats.day().wordsCompleted == 3)
        #expect(stats.totalWords == 3)
        #expect(stats.recent(7).count == 7)
    }

    @Test func samplesGrowInPlaceAndFeedVocabulary() {
        var samples = WritingSamples()
        let first = "Thanks for reaching out about the server migration."
        samples.add(first, app: "mail")
        samples.add(first + " The migration finishes tonight.", app: "mail")
        samples.add("short", app: "mail")
        #expect(samples.samples.count == 1)
        samples.add("Totally different note about the migration schedule here.", app: "notes")
        #expect(samples.relevant(for: "notes", limit: 1).first?.hasPrefix("Totally") == true)
        let vocabulary = samples.vocabulary()
        #expect(vocabulary["migration"] == 1.0)
        #expect(vocabulary["Thanks"] == nil)
    }
}

@Suite struct TextAnalysisTests {
    @Test func completedWord() {
        #expect(TextAnalysis.justCompletedWord(in: "I recieve ")?.word == "recieve")
        #expect(TextAnalysis.justCompletedWord(in: "I recieve") == nil)
        #expect(TextAnalysis.justCompletedWord(in: "ask NASA ") == nil)
        #expect(TextAnalysis.justCompletedWord(in: "version2 ") == nil)
        #expect(TextAnalysis.isSingleWord("quick"))
        #expect(!TextAnalysis.isSingleWord("quick fox"))
    }
}

@Suite struct SecretSanitizerTests {
    @Test func redactsSecretsButKeepsProse() {
        #expect(SecretSanitizer.sanitize("Pay to DE89 3704 0044 0532 0130 00 today") == "Pay to [redacted] today")
        #expect(SecretSanitizer.sanitize("card 4242 4242 4242 4242 ok") == "card [redacted] ok")
        #expect(SecretSanitizer.sanitize("order 1234 5678 9012 3456 7") == "order 1234 5678 9012 3456 7")
        #expect(SecretSanitizer.sanitize("key sk-proj-abcdefghijklmnop1234 end") == "key [redacted] end")
        #expect(SecretSanitizer.sanitize("password: hunter2 please") == "[redacted] please")
        let prose = "Thanks for the update — see you at 10:30 on the 14th, internationalization included."
        #expect(SecretSanitizer.sanitize(prose) == prose)
    }
}
