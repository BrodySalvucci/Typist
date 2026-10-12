import AppKit
import Carbon.HIToolbox
import TypistCore

/// Ties everything together: watches typing, decides what to offer (a
/// completion, an emoji, a typo fix, or word alternatives), shows it, and
/// handles accepting or dismissing it.
///
/// Main-thread only.
final class CompletionCoordinator {
    private struct Completion {
        var suggestion: Suggestion
        /// The text before the caret that `suggestion` continues. Grows as the
        /// user accepts words or types through the suggestion.
        var anchor: String
        /// Until the first word of it has been accepted (for statistics).
        var fresh = true
    }

    private enum Proposal {
        case completion(Completion)
        /// Replace the last `delete` characters with `insert` (emoji, typo fix).
        case replacement(delete: Int, insert: String)
    }

    private let state = AppState.shared
    private let interceptor = KeyInterceptor()
    private let overlay = SuggestionOverlay()
    private let screen = ScreenContext()
    private let promptBuilder = PromptBuilder()
    /// Accessibility calls can take tens of milliseconds in some apps. The
    /// event tap runs on the main thread, so anything slow there delays the
    /// user's own key presses; all reading happens on this queue instead.
    private let readQueue = DispatchQueue(label: "typist.accessibility", qos: .userInteractive)
    /// Bumped whenever the user does something; results of older reads are dropped.
    private var readToken = 0

    private var proposal: Proposal?
    /// Word alternatives currently offered for the selection.
    private var alternatives: [String]?
    private var refreshWork: DispatchWorkItem?
    private var selectionWork: DispatchWorkItem?
    /// Latest text seen in the current field, stored as a writing sample once the user moves on.
    private var pendingSample: (app: String, text: String)?
    private var batteryCheck: (date: Date, onBattery: Bool)?

    /// Website being edited when a text field was last read; shown in the menu.
    private(set) var lastDomain: String?

    /// Pause after the last key press before asking the model.
    private let debounce: TimeInterval = 0.12
    /// How often to re-read the text field while waiting for the host app to
    /// process a key press, and how many times before giving up.
    private let settleInterval: TimeInterval = 0.03
    private let settleAttempts = 12

    private var prefs: Preferences { state.prefs }
    private var engine: LlamaEngine { state.engine }

    init() {
        interceptor.handler = { [weak self] in self?.handle($0) ?? false }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.readQueue.async { AccessibilityReader.enableAccessibilityTree(for: app) }
            }
            self?.state.pause.appOffUntilSwitch = nil
            self?.lastDomain = nil
            self?.commitSample()
            self?.dismiss()
        }
    }

    /// Returns `false` until Accessibility permission is granted.
    @discardableResult
    func start() -> Bool {
        let started = interceptor.start()
        Log.debug("event tap started=\(started) trusted=\(AccessibilityReader.isTrusted)")
        if started, let app = frontApp { readQueue.async { AccessibilityReader.enableAccessibilityTree(for: app) } }
        return started
    }

    func flush() {
        commitSample()
    }

    // MARK: - State

    private var frontApp: NSRunningApplication? { NSWorkspace.shared.frontmostApplication }

    private var isOwnAppFrontmost: Bool {
        frontApp?.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

    private var onBattery: Bool {
        if let batteryCheck, Date().timeIntervalSince(batteryCheck.date) < 30 { return batteryCheck.onBattery }
        let value = PowerSource.isOnBattery
        batteryCheck = (Date(), value)
        return value
    }

    private func isActive(in app: NSRunningApplication?) -> Bool {
        guard let app, !isOwnAppFrontmost, !IsSecureEventInputEnabled() else { return false }
        let bundleID = app.bundleIdentifier
        return prefs.isEnabled(inApp: bundleID)
            && !state.pause.isPaused(app: bundleID)
            && !(prefs.pauseOnBattery && onBattery)
    }

    // MARK: - Input

    private func handle(_ event: InputEvent) -> Bool {
        switch event {
        case .mouseDown:
            dismiss()
            return false
        case .mouseUp:
            scheduleSelectionCheck()
            return false
        case .key(let key):
            return handle(key)
        }
    }

    private func handle(_ key: KeyEvent) -> Bool {
        // The shortcut recorder in Settings must see every key.
        if isOwnAppFrontmost { return false }
        let app = frontApp
        let bundleID = app?.bundleIdentifier

        if key.matches(prefs.toggleGlobalShortcut) {
            state.settings.prefs.enabled.toggle()
            dismiss()
            return true
        }
        if key.matches(prefs.toggleAppShortcut), let bundleID {
            togglePause(app: bundleID)
            return true
        }
        if prefs.wordAlternatives, key.matches(prefs.alternativesShortcut) {
            showAlternatives()
            return true
        }

        guard isActive(in: app) else {
            dismiss()
            return false
        }

        let commandLike = !key.flags.intersection([.maskCommand, .maskControl]).isEmpty
        let plainEscape = Int(key.keyCode) == kVK_Escape && key.modifiers == 0

        if let alternatives {
            if !commandLike, let number = Int(key.characters), (1...alternatives.count).contains(number) {
                let choice = alternatives[number - 1]
                dismiss()
                TextInserter.insert(choice)
                scheduleRefresh()
                return true
            }
            dismiss()
            if plainEscape { return true }
        }

        if let proposal {
            let tabLeftToApp = prefs.app(bundleID).tabDisabled && Int(key.keyCode) == kVK_Tab
            let acceptWord = key.matches(prefs.acceptWordShortcut) && !tabLeftToApp
            let acceptAll = key.matches(prefs.acceptAllShortcut) && !tabLeftToApp

            switch proposal {
            case .completion(var completion):
                if acceptWord || acceptAll {
                    let options = Suggestion.AcceptOptions(
                        includeTrailingSpace: prefs.acceptTrailingSpace,
                        includeAttachedPunctuation: prefs.acceptAttachedPunctuation)
                    let text = acceptAll ? completion.suggestion.acceptAll() : completion.suggestion.acceptNextChunk(options)
                    accept(text, leaving: completion)
                    return true
                }
                // Typing exactly what was suggested keeps the suggestion alive.
                if !commandLike, completion.suggestion.consume(typed: key.characters), !completion.suggestion.isEmpty {
                    completion.anchor += key.characters
                    self.proposal = .completion(completion)
                    settle()
                    return false
                }
            case .replacement(let delete, let insert):
                if acceptWord || acceptAll {
                    dismiss()
                    TextInserter.replace(last: delete, with: insert)
                    state.stats.value.recordAccepted(insert, firstOfSuggestion: true)
                    scheduleRefresh()
                    return true
                }
            }
            dismiss()
            if plainEscape {
                applyEscapeBehavior(app: bundleID)
                return true
            }
        }

        scheduleRefresh()
        if key.flags.contains(.maskShift) { scheduleSelectionCheck() }
        return false
    }

    /// Types `text` into the app. What is left of the suggestion stays up: the
    /// typed word lands exactly where its ghost was, so the overlay is only
    /// moved once the app has caught up, with no flicker and no new model call.
    private func accept(_ text: String, leaving rest: Completion) {
        TextInserter.insert(text)
        state.stats.value.recordAccepted(text, firstOfSuggestion: rest.fresh)
        Log.debug("accepted \(text.count) chars, \(rest.suggestion.remaining.count) left")
        if rest.suggestion.isEmpty {
            proposal = nil
            overlay.hide()
            scheduleRefresh()
        } else {
            var rest = rest
            rest.anchor += text
            rest.fresh = false
            proposal = .completion(rest)
            settle()
        }
    }

    private func dismiss() {
        readToken += 1
        refreshWork?.cancel()
        selectionWork?.cancel()
        engine.cancel()
        proposal = nil
        alternatives = nil
        overlay.hide()
    }

    private func applyEscapeBehavior(app bundleID: String?) {
        guard let bundleID else { return }
        switch prefs.escapeBehavior {
        case .dismiss: break
        case .pauseBriefly: state.pause.pause(app: bundleID, for: 10)
        case .offUntilAppSwitch: state.pause.appOffUntilSwitch = bundleID
        }
    }

    func togglePause(app bundleID: String) {
        if state.pause.isPaused(app: bundleID) {
            state.pause.resume(app: bundleID)
        } else {
            state.pause.pause(app: bundleID, for: TimeInterval(prefs.pauseMinutes * 60))
            dismiss()
        }
    }

    // MARK: - Proposals

    private func scheduleRefresh() {
        refreshWork?.cancel()
        engine.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    /// Reads the focused text field on the background queue. `completion` runs
    /// on the main queue unless the user has done something else meanwhile.
    private func read(in app: NSRunningApplication, completion: @escaping (FocusSnapshot?) -> Void) {
        let token = readToken
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        readQueue.async {
            let snapshot = AccessibilityReader.snapshot(primaryScreenHeight: screenHeight)
            if snapshot == nil {
                Log.debug("read: \(app.bundleIdentifier ?? "?"): \(AccessibilityReader.lastFailure)")
                // Chromium and Electron build their accessibility tree on request;
                // ask (again) so the next key press finds the text field.
                AccessibilityReader.enableAccessibilityTree(for: app)
            }
            DispatchQueue.main.async {
                if token == self.readToken { completion(snapshot) }
            }
        }
    }

    private func refresh() {
        guard let app = frontApp, isActive(in: app) else { return Log.debug("refresh: inactive in \(frontApp?.bundleIdentifier ?? "?")") }
        read(in: app) { [weak self] snapshot in
            if let snapshot { self?.propose(for: snapshot, in: app) }
        }
    }

    private func propose(for snapshot: FocusSnapshot, in app: NSRunningApplication) {
        let bundleID = app.bundleIdentifier
        Log.debug("refresh: \(bundleID ?? "?") before=\(snapshot.before.count) after=\(snapshot.after.count) caret=\(snapshot.caretRect.map { "\($0)" } ?? "nil") field=\(snapshot.fieldSize.map { "\($0)" } ?? "nil")")
        lastDomain = snapshot.domain
        guard prefs.isEnabled(onDomain: snapshot.domain) else { return }
        recordSample(snapshot, app: bundleID)

        if snapshot.hasSelection { return }
        if !prefs.smallFields, let size = snapshot.fieldSize, size.width > 0, size.width < 150 { return Log.debug("small field skipped") }

        if prefs.emojiEnabled, let caret = snapshot.caretRect,
           let query = EmojiCatalog.query(in: snapshot.before), let emoji = EmojiCatalog.search(query, limit: 1).first {
            let rendered = EmojiCatalog.render(emoji, skinTone: prefs.emojiSkinTone)
            proposal = .replacement(delete: query.count + 1, insert: rendered)
            overlay.showCard(card("\(rendered)  :\(emoji.shortcodes[0]):"), below: caret)
            return
        }

        if prefs.typoDetection, let fix = TypoChecker.fix(for: snapshot.before) {
            // Never build a completion on top of a likely typo.
            if prefs.showTypoFixes, let caret = snapshot.caretRect {
                proposal = .replacement(delete: fix.deleteCount, insert: fix.replacement)
                let text = NSMutableAttributedString(string: fix.original, attributes: [
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NSColor.secondaryLabelColor,
                ])
                text.append(NSAttributedString(string: "  " + fix.corrected, attributes: [.foregroundColor: NSColor.labelColor]))
                overlay.showCard(card(text), below: caret)
            }
            return
        }

        requestCompletion(for: snapshot, in: app)
    }

    private func requestCompletion(for snapshot: FocusSnapshot, in app: NSRunningApplication) {
        let bundleID = app.bundleIdentifier
        let override = prefs.app(bundleID)
        let policy = CompletionPolicy(allowMidLine: override.midLine.resolved(default: prefs.allowMidLine))
        guard engine.isLoaded,
              policy.shouldComplete(before: snapshot.before, after: snapshot.after, hasSelection: snapshot.hasSelection)
        else { return Log.debug("completion skipped: engineLoaded=\(engine.isLoaded)") }

        var maxWords = prefs.maxWords
        if prefs.shorterOnBattery, onBattery { maxWords = min(maxWords, 4) }

        engine.complete(prompt: prompt(for: snapshot, in: app),
                        options: GenerationOptions(maxWords: maxWords, eagerness: prefs.eagerness)) { [weak self] result in
            Log.debug("engine result: \(result.map { "\($0.text.count) chars" } ?? "none")")
            guard let self, let result, self.proposal == nil, self.alternatives == nil,
                  let suggestion = Suggestion.make(raw: result.text, before: snapshot.before, maxWords: maxWords, truncated: result.truncated)
            else { return }
            Log.debug("suggestion \(suggestion.remaining.count) chars")
            self.proposal = .completion(Completion(suggestion: suggestion, anchor: snapshot.before))
            self.show(suggestion, for: snapshot, in: app)
            self.state.stats.value.recordShown()
        }
    }

    private func prompt(for snapshot: FocusSnapshot, in app: NSRunningApplication) -> String {
        let bundleID = app.bundleIdentifier
        var input = PromptInput(before: snapshot.before)
        input.instructions = [
            prefs.instructions,
            prefs.app(bundleID).instructions,
            snapshot.domain.flatMap { prefs.domains[$0]?.instructions } ?? "",
        ].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n")

        if prefs.useWindowContext {
            input.appName = app.localizedName
            input.windowTitle = snapshot.windowTitle
            input.fieldHint = snapshot.placeholder
        }
        if prefs.useScreenContext {
            input.screenText = screen.text(for: app.processIdentifier).map(SecretSanitizer.sanitize)
        }
        if prefs.useClipboardContext {
            let pasteboard = NSPasteboard.general
            // Password managers mark secrets as concealed; leave those alone.
            let concealed = pasteboard.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) ?? false
            if !concealed { input.clipboard = pasteboard.string(forType: .string).map(SecretSanitizer.sanitize) }
        }
        if prefs.recordWriting, prefs.personalizationStrength > 0, let bundleID {
            input.samples = state.samples.value.relevant(for: bundleID, limit: 2)
        }
        return promptBuilder.build(input)
    }

    /// After the user typed or accepted part of the completion: waits until the
    /// app's text matches what the rest of the suggestion continues, then moves
    /// the overlay to the new caret position.
    private func settle(attempt: Int = 0) {
        if attempt == 0 { readToken += 1 }
        guard case .completion = proposal, let app = frontApp, isActive(in: app) else { return }
        read(in: app) { [weak self] snapshot in
            guard let self, case .completion(let completion) = self.proposal else { return }
            if let snapshot, !snapshot.hasSelection, snapshot.before == completion.anchor {
                self.show(completion.suggestion, for: snapshot, in: app)
            } else if attempt < self.settleAttempts {
                let token = self.readToken
                DispatchQueue.main.asyncAfter(deadline: .now() + self.settleInterval) {
                    if token == self.readToken { self.settle(attempt: attempt + 1) }
                }
            } else {
                // The app did something else with the text (autocorrect, formatting): start over.
                Log.debug("settle: text never matched, dropping suggestion")
                self.dismiss()
                self.scheduleRefresh()
            }
        }
    }

    private func show(_ suggestion: Suggestion, for snapshot: FocusSnapshot, in app: NSRunningApplication) {
        let override = prefs.app(app.bundleIdentifier)
        if let caret = snapshot.caretRect {
            overlay.showGhost(suggestion.remaining, at: caret, fontScale: override.fontScale, verticalOffset: override.verticalOffset)
        } else if let field = snapshot.fieldFrame {
            // The app doesn't say where the caret is: show the suggestion under the field instead.
            overlay.showCard(card(suggestion.remaining.trimmingCharacters(in: .whitespaces)), below: field)
        } else {
            proposal = nil
            overlay.hide()
        }
    }

    private func card(_ text: String) -> NSAttributedString {
        card(NSAttributedString(string: text, attributes: [.foregroundColor: NSColor.labelColor]))
    }

    /// Adds the font and the accept-key hint used by all cards.
    private func card(_ text: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        if let label = prefs.acceptWordShortcut?.label {
            result.append(NSAttributedString(string: "   " + label, attributes: [.foregroundColor: NSColor.tertiaryLabelColor]))
        }
        result.addAttribute(.font, value: NSFont.systemFont(ofSize: 13), range: NSRange(location: 0, length: result.length))
        return result
    }

    // MARK: - Word alternatives

    private func scheduleSelectionCheck() {
        selectionWork?.cancel()
        guard prefs.wordAlternatives, prefs.autoShowAlternatives else { return }
        let work = DispatchWorkItem { [weak self] in self?.showAlternatives() }
        selectionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Offers words picked by number: replacements for the selected word, or,
    /// without a selection, alternatives to the word Typist would suggest next.
    private func showAlternatives() {
        guard let app = frontApp, isActive(in: app), engine.isLoaded else { return }
        let suggested: String
        if case .completion(let completion) = proposal {
            suggested = completion.suggestion.nextChunk().trimmingCharacters(in: .whitespaces)
        } else {
            suggested = ""
        }
        dismiss()
        read(in: app) { [weak self] snapshot in
            if let snapshot { self?.showAlternatives(for: snapshot, in: app, suggested: suggested) }
        }
    }

    private func showAlternatives(for snapshot: FocusSnapshot, in app: NSRunningApplication, suggested: String) {
        let anchor: CGRect?
        let current: String
        if snapshot.hasSelection {
            guard TextAnalysis.isSingleWord(snapshot.selectedText) else { return }
            anchor = snapshot.selectionRect ?? snapshot.caretRect
            current = snapshot.selectedText.trimmingCharacters(in: .whitespaces)
        } else {
            anchor = snapshot.caretRect ?? snapshot.fieldFrame
            current = suggested
        }
        guard let anchor else { return }
        let token = readToken

        // After a space only whole words fit; mid-word, only continuations of it.
        let afterSpace = snapshot.before.last?.isWhitespace ?? true
        engine.alternatives(prompt: prompt(for: snapshot, in: app), excluding: current, count: 10) { [weak self] words in
            // Any key press or click since the request makes the list stale.
            guard let self, self.proposal == nil, token == self.readToken else { return }
            let capitalized = snapshot.hasSelection && (current.first?.isUppercase ?? false)
            let choices: [String] = words
                .filter { $0.hasPrefix(" ") == afterSpace || snapshot.before.isEmpty }
                .map { afterSpace ? String($0.dropFirst($0.hasPrefix(" ") ? 1 : 0)) : $0 }
                .map { capitalized ? $0.prefix(1).uppercased() + $0.dropFirst() : $0 }
                .prefix(5).map { $0 }
            guard !choices.isEmpty else { return }
            self.alternatives = choices

            let text = NSMutableAttributedString()
            for (index, choice) in choices.enumerated() {
                text.append(NSAttributedString(string: "\(index + 1)  ", attributes: [.foregroundColor: NSColor.tertiaryLabelColor]))
                text.append(NSAttributedString(string: choice + (index < choices.count - 1 ? "\n" : ""), attributes: [.foregroundColor: NSColor.labelColor]))
            }
            text.addAttribute(.font, value: NSFont.systemFont(ofSize: 13), range: NSRange(location: 0, length: text.length))
            self.overlay.showCard(text, below: anchor)
        }
    }

    // MARK: - Personalization

    private func recordSample(_ snapshot: FocusSnapshot, app bundleID: String?) {
        guard prefs.recordWriting, let bundleID, prefs.app(bundleID).recordWriting else { return }
        let text = snapshot.before + snapshot.after
        // A much shorter text means the field was cleared (message sent) or
        // another field got focus: keep what was written before.
        if let pendingSample, pendingSample.app != bundleID || text.count < pendingSample.text.count / 2 {
            commitSample()
        }
        pendingSample = (bundleID, text)
    }

    private func commitSample() {
        guard let sample = pendingSample else { return }
        pendingSample = nil
        let before = state.samples.value
        state.samples.value.add(SecretSanitizer.sanitize(sample.text), app: sample.app)
        if state.samples.value != before { state.refreshPersonalization() }
    }
}
