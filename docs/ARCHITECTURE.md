# Architecture

Typist is a menu-bar app (`LSUIElement`) with two targets:

- **TypistCore** — pure Swift, no UI or system APIs. Unit tested.
- **Typist** — the app: Accessibility, event tap, llama.cpp, overlay, menu.

## The loop

```
key press ──► KeyInterceptor (CGEventTap)
                 │
                 ▼
        CompletionCoordinator ──(debounce 120 ms)──► AccessibilityReader.snapshot()
                 │                                        text before/after caret, caret rect
                 │◄───────────────────────────────────────┘
                 │  CompletionPolicy.shouldComplete?
                 ▼
            PromptBuilder ──► LlamaEngine.complete ──► Suggestion.make
                                                            │
                 ┌──────────────────────────────────────────┘
                 ▼
          SuggestionOverlay (ghost text at caret)
                 │
   Tab / Shift-Tab ──► TextInserter (synthetic Unicode key events)
```

## Components

**TypistCore**

| File | Role |
| --- | --- |
| `Preferences` | All settings as one Codable value (per-app and per-site overrides, shortcuts). Decoding fills in defaults for fields added later. |
| `PromptBuilder` | Lays out instructions, writing samples, screen text, clipboard and location as a document header, followed by the text before the caret. The text window only moves in fixed steps so consecutive prompts share a prefix. |
| `CompletionPolicy` | When to suggest: enough context, no selection, end of line unless mid-line is enabled. |
| `Suggestion` | Cleans model output (single line, word limit, no doubled spaces) and tracks what is left as the user accepts words or types through it. |
| `Emoji` | Shortcode catalog, query detection, search, skin tones. |
| `TextAnalysis` | Finds the just-completed word (typo check) and single-word selections. |
| `WritingSamples` | Recorded writing and the vocabulary derived from it. |
| `SecretSanitizer` | Redacts card numbers, IBANs, tokens and keys before text is stored or used as context. |
| `UsageStats` | Per-day counters. |

**Typist (app)**

| File | Role |
| --- | --- |
| `CompletionCoordinator` | State machine: key handling, choosing between completion / emoji / typo fix / word alternatives, accepting, pausing, sample recording. |
| `AccessibilityReader` | Reads the focused element: text, selection, caret and selection bounds, field size, placeholder, window title, web page host. Skips secure fields. Sets `AXManualAccessibility` so Chromium/Electron apps expose their text. |
| `KeyInterceptor` | Session event tap. Sees keys first and swallows shortcuts. Events posted by Typist carry a marker and are ignored. |
| `LlamaEngine` | Greedy decoding on a serial queue. New requests cancel old ones. Reuses the KV cache for the shared prompt prefix. Stops when the top-token probability drops. Applies a logit bonus to the user's frequent words. Also produces ranked next-word alternatives. |
| `SuggestionOverlay` | Click-through, non-activating panel: ghost text at the caret, or a card below it. |
| `TextInserter` | Posts key events carrying text (`CGEventKeyboardSetUnicodeString`) and backspaces for replacements; clipboard untouched. |
| `ScreenContext` | ScreenCaptureKit screenshot of the front window + Vision OCR, cached for 20 s, in memory only. |
| `SystemHelpers` | Battery state, login item, typo check via `NSSpellChecker`, shortcut recording. |
| `Stores` | `SettingsStore` (UserDefaults), `FileStore` (JSON in Application Support), `PauseState`, `AppState`. |
| `ModelStore` | Model catalog, downloads, installed GGUF files. |
| `SettingsView` | SwiftUI settings window. |
| `AppDelegate` | Status item, menu, wiring. |

## Design notes

- **Base models, raw continuation.** The prompt is the document itself, not a
  chat. This is fast (no template overhead) and gives natural continuations.
- **Confidence gating.** `GenerationOptions.minFirstTokenProbability` and
  `minTokenProbability` trade recall for precision. A suggestion that is wrong
  costs the user more than no suggestion.
- **Privacy.** No network access except the model download the user starts
  from the menu. No telemetry. Completions are disabled while macOS Secure
  Input is active and in secure text fields.

## Ideas for contributors

- Match the host app's font and text color
- Multi-word phrase alternatives; instruct-model support for rewriting
- Smarter insertion for apps that drop synthetic key events (paste fallback)
- Emoji picker with several candidates; gender variants
- Signed and notarized releases with automatic updates
