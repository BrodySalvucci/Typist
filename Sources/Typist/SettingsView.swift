import AppKit
import Charts
import SwiftUI
import TypistCore

/// `SwiftUI.State` under another name. Recent SDKs also offer `@State` as a
/// macro whose compiler plugin ships only with Xcode; going through the type
/// keeps the project buildable with just the Command Line Tools.
typealias ViewState<Value> = SwiftUI.State<Value>

enum SettingsPane: String, CaseIterable, Identifiable {
    case setup, general, model, context, personalization, apps, shortcuts, emoji, battery, statistics, labs, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .setup: return "Setup"
        case .general: return "General"
        case .model: return "AI Model"
        case .context: return "Context"
        case .personalization: return "Personalization"
        case .apps: return "Apps & Websites"
        case .shortcuts: return "Shortcuts"
        case .emoji: return "Emoji"
        case .battery: return "Battery"
        case .statistics: return "Statistics"
        case .labs: return "Labs"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .setup: return "checklist"
        case .general: return "gearshape"
        case .model: return "cpu"
        case .context: return "eye"
        case .personalization: return "person.text.rectangle"
        case .apps: return "square.grid.2x2"
        case .shortcuts: return "keyboard"
        case .emoji: return "face.smiling"
        case .battery: return "battery.75percent"
        case .statistics: return "chart.bar"
        case .labs: return "flask"
        case .about: return "info.circle"
        }
    }
}

struct SettingsView: View {
    @ViewState var pane: SettingsPane

    init(initialPane: SettingsPane) {
        _pane = ViewState(initialValue: initialPane)
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: Binding(get: { pane }, set: { pane = $0 ?? pane })) { pane in
                Label(pane.title, systemImage: pane.symbol).tag(pane)
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            Group {
                switch pane {
                case .setup: SetupPane()
                case .general: GeneralPane()
                case .model: ModelPane()
                case .context: ContextPane()
                case .personalization: PersonalizationPane()
                case .apps: AppsPane()
                case .shortcuts: ShortcutsPane()
                case .emoji: EmojiPane()
                case .battery: BatteryPane()
                case .statistics: StatisticsPane()
                case .labs: LabsPane()
                case .about: AboutPane()
                }
            }
            .navigationTitle(pane.title)
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}

// MARK: - Setup

private struct SetupPane: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var models: ModelStore
    @EnvironmentObject var engine: EngineStatus
    @ViewState private var trusted = AccessibilityReader.isTrusted
    @ViewState private var screenAccess = ScreenContext.hasPermission
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Text("Typist completes what you type, in any app. Everything runs on this Mac; nothing you write is sent anywhere.")
            }
            Section("1. Accessibility access") {
                step(done: trusted, "Lets Typist read the text field you are typing in, see the Tab key, and type accepted suggestions.")
                if !trusted {
                    Button("Open Accessibility Settings…") {
                        AccessibilityReader.requestTrust()
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
            }
            Section("2. AI model") {
                step(done: !models.installed.isEmpty, "Download a language model to generate completions. Recommended for this Mac: \(ModelStore.recommended.name) (\(ModelStore.recommended.sizeGB.formatted()) GB).")
                if let downloading = models.downloading {
                    ProgressView(value: models.progress) { Text("Downloading \(downloading.name)… \(Int(models.progress * 100))%") }
                } else if models.installed.isEmpty {
                    Button("Download \(ModelStore.recommended.name)") { AppState.shared.download(ModelStore.recommended) }
                } else if case .failed(let message) = engine.phase {
                    Text(message).foregroundStyle(.red)
                }
                if let error = models.lastError { Text(error).foregroundStyle(.red) }
            }
            Section("3. Screen context (optional)") {
                step(done: screenAccess && settings.prefs.useScreenContext, "Lets Typist read the text around your text field so suggestions fit the email or chat you are answering. Processed on this Mac, never stored.")
                if !screenAccess {
                    Button("Grant Screen Recording Access…") { ScreenContext.requestPermission() }
                } else {
                    Toggle("Use screen context", isOn: $settings.prefs.useScreenContext)
                }
            }
            Section {
                Text("Then just type. **\(settings.prefs.acceptWordShortcut?.label ?? "—")** accepts the next word, **\(settings.prefs.acceptAllShortcut?.label ?? "—")** the whole suggestion, **⎋** dismisses it.")
            }
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in
            trusted = AccessibilityReader.isTrusted
            screenAccess = ScreenContext.hasPermission
            if trusted, !models.installed.isEmpty { settings.prefs.onboardingDone = true }
        }
    }

    private func step(done: Bool, _ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: done ? "checkmark.circle.fill" : "circle").foregroundStyle(done ? .green : .secondary)
        }
    }
}

// MARK: - General

private struct GeneralPane: View {
    @EnvironmentObject var settings: SettingsStore
    @ViewState private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        Form {
            Section {
                Toggle("Enable completions", isOn: $settings.prefs.enabled)
                Toggle("Enabled in all apps by default", isOn: $settings.prefs.enabledByDefault)
                Text("When off, completions only appear in apps you enable individually under Apps & Websites.").caption()
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { LoginItem.setEnabled($0) }
                Toggle("Show today's word count in the menu bar", isOn: $settings.prefs.showWordCountInMenuBar)
            }
            Section("Suggestions") {
                Picker("Length", selection: $settings.prefs.maxWords) {
                    Text("Short (up to 4 words)").tag(4)
                    Text("Medium (up to 8 words)").tag(8)
                    Text("Long (up to 16 words)").tag(16)
                    Text("Very long (up to 30 words)").tag(30)
                }
                VStack(alignment: .leading) {
                    Slider(value: $settings.prefs.eagerness, in: 0...1) { Text("Eagerness") } minimumValueLabel: { Text("Careful") } maximumValueLabel: { Text("Eager") }
                    Text("Careful shows fewer suggestions, but they are more often right.").caption()
                }
                Toggle("Suggest in the middle of a line", isOn: $settings.prefs.allowMidLine)
                Text("Normally suggestions only appear at the end of a line you are still writing.").caption()
                Toggle("Suggest in small text fields", isOn: $settings.prefs.smallFields)
            }
            Section("Accepting") {
                Toggle("Include the space after an accepted word", isOn: $settings.prefs.acceptTrailingSpace)
                Toggle("Accept punctuation attached to a word along with it", isOn: $settings.prefs.acceptAttachedPunctuation)
            }
            Section("Typos") {
                Toggle("Hold back suggestions after a likely typo", isOn: $settings.prefs.typoDetection)
                Toggle("Offer a fix for the typo", isOn: $settings.prefs.showTypoFixes).disabled(!settings.prefs.typoDetection)
                Text("Only looks at the word you just finished, so it won't replace a real spell checker.").caption()
            }
            Section("Pausing") {
                Picker("Escape key", selection: $settings.prefs.escapeBehavior) {
                    Text("Dismisses the suggestion").tag(EscapeBehavior.dismiss)
                    Text("Also pauses completions briefly").tag(EscapeBehavior.pauseBriefly)
                    Text("Turns completions off until you switch apps").tag(EscapeBehavior.offUntilAppSwitch)
                }
                Stepper("Pause duration: \(settings.prefs.pauseMinutes) minutes", value: $settings.prefs.pauseMinutes, in: 1...120)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Model

private struct ModelPane: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var models: ModelStore
    @EnvironmentObject var engine: EngineStatus

    var body: some View {
        Form {
            Section("Installed") {
                if models.installed.isEmpty {
                    Text("No model installed yet.").foregroundStyle(.secondary)
                }
                let active = models.active(selected: settings.prefs.selectedModel)
                ForEach(models.installed, id: \.self) { url in
                    HStack {
                        Image(systemName: url == active ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(url == active ? Color.accentColor : .secondary)
                        VStack(alignment: .leading) {
                            Text(models.displayName(for: url))
                            if url == active { Text(statusText).caption() }
                        }
                        Spacer()
                        Button("Delete", role: .destructive) { models.delete(url) }.disabled(url == active && models.installed.count > 1)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { settings.prefs.selectedModel = url.lastPathComponent }
                }
                Button("Open Models Folder") { NSWorkspace.shared.open(models.directory) }
                Text("Any GGUF text model placed in this folder can be used. Base (non-chat) models work best.").caption()
            }
            Section("Download") {
                if let downloading = models.downloading {
                    ProgressView(value: models.progress) { Text("Downloading \(downloading.name)… \(Int(models.progress * 100))%") }
                    Button("Cancel") { models.cancelDownload() }
                }
                if let error = models.lastError { Text(error).foregroundStyle(.red) }
                ForEach(ModelStore.catalog) { model in
                    HStack {
                        VStack(alignment: .leading) {
                            HStack {
                                Text(model.name)
                                if model == ModelStore.recommended { Text("Recommended").font(.caption).padding(.horizontal, 6).background(.tint.opacity(0.2), in: Capsule()) }
                            }
                            Text("\(model.sizeGB.formatted()) GB · \(model.note)").caption()
                            if ModelStore.memoryGB < model.minimumMemoryGB {
                                Text("May be slow: this Mac has \(ModelStore.memoryGB) GB of memory.").font(.caption).foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        if models.isInstalled(model) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button("Download") { AppState.shared.download(model) }.disabled(models.downloading != nil)
                        }
                    }
                }
                Text("Models are downloaded from Hugging Face and have their own licenses.").caption()
            }
        }
        .formStyle(.grouped)
    }

    private var statusText: String {
        switch engine.phase {
        case .noModel: return "Not loaded"
        case .loading: return "Loading…"
        case .ready: return "In use"
        case .failed(let message): return "Failed to load: \(message)"
        }
    }
}

// MARK: - Context

private struct ContextPane: View {
    @EnvironmentObject var settings: SettingsStore
    @ViewState private var screenAccess = ScreenContext.hasPermission
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Toggle("Use the app name and window title", isOn: $settings.prefs.useWindowContext)
                Text("Tells the model where you are writing, e.g. the subject of the email.").caption()
            }
            Section("Screen") {
                Toggle("Read the text around the text field", isOn: $settings.prefs.useScreenContext).disabled(!screenAccess)
                Text("Typist takes a picture of the window you are typing in and reads its text, so suggestions match the email thread, document or chat. Processed on this Mac; never stored or sent anywhere.").caption()
                if !screenAccess {
                    Button("Grant Screen Recording Access…") { ScreenContext.requestPermission() }
                    Text("Requires Screen Recording permission. You may need to relaunch Typist afterwards.").caption()
                }
            }
            Section("Clipboard") {
                Toggle("Use the clipboard", isOn: $settings.prefs.useClipboardContext)
                Text("Lets suggestions build on what you just copied. Entries marked as secret by password managers are ignored.").caption()
            }
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in screenAccess = ScreenContext.hasPermission }
    }
}

// MARK: - Personalization

private struct PersonalizationPane: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var samples: FileStore<WritingSamples>
    @ViewState private var confirmDelete = false

    var body: some View {
        Form {
            Section("About you") {
                TextEditor(text: $settings.prefs.instructions).frame(minHeight: 90).font(.body)
                Text("Your name, role, languages, tone. Typist factors this into every suggestion. Apps and websites can add their own under Apps & Websites.").caption()
            }
            Section("Learn from your writing") {
                Toggle("Record what I write in fields where Typist suggests text", isOn: $settings.prefs.recordWriting)
                Text("Recorded text stays in a file on this Mac and is used to make suggestions sound like you. Password fields are never recorded. Recording can be turned off per app.").caption()
                VStack(alignment: .leading) {
                    Slider(value: $settings.prefs.personalizationStrength, in: 0...1) { Text("Strength") } minimumValueLabel: { Text("Off") } maximumValueLabel: { Text("Strong") }
                    Text("How strongly suggestions lean toward your own words and phrases. Too high may occasionally pick a less fitting word.").caption()
                }
                .disabled(!settings.prefs.recordWriting)
                LabeledContent("Recorded texts", value: "\(samples.value.samples.count)")
                Button("Delete Recorded Writing…", role: .destructive) { confirmDelete = true }
                    .disabled(samples.value.samples.isEmpty)
                    .confirmationDialog("Delete everything Typist has recorded of your writing?", isPresented: $confirmDelete) {
                        Button("Delete", role: .destructive) {
                            samples.value.removeAll()
                            AppState.shared.refreshPersonalization()
                        }
                    }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Apps & websites

private struct AppsPane: View {
    @EnvironmentObject var settings: SettingsStore
    @ViewState private var selection: String?
    @ViewState private var newDomain = ""

    private var bundleIDs: [String] {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier)
            .filter { $0 != Bundle.main.bundleIdentifier }
        return Set(running).union(settings.prefs.apps.keys).sorted { Self.name(for: $0).localizedCaseInsensitiveCompare(Self.name(for: $1)) == .orderedAscending }
    }

    static func name(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    var body: some View {
        HSplitView {
            List(selection: $selection) {
                Section("Apps") {
                    ForEach(bundleIDs, id: \.self) { bundleID in
                        HStack {
                            Text(Self.name(for: bundleID))
                            Spacer()
                            if settings.prefs.apps[bundleID].map({ $0 != AppOverride() }) ?? false {
                                Image(systemName: "slider.horizontal.3").foregroundStyle(.secondary)
                            }
                        }
                        .tag("app:" + bundleID)
                    }
                }
                Section("Websites") {
                    ForEach(settings.prefs.domains.keys.sorted(), id: \.self) { domain in
                        Text(domain).tag("site:" + domain)
                    }
                    HStack {
                        TextField("example.com", text: $newDomain).onSubmit(addDomain)
                        Button("Add", action: addDomain).disabled(newDomain.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .frame(minWidth: 210, maxWidth: 260)

            Group {
                if let selection, selection.hasPrefix("app:") {
                    appDetail(String(selection.dropFirst(4)))
                } else if let selection, selection.hasPrefix("site:") {
                    domainDetail(String(selection.dropFirst(5)))
                } else {
                    Text("Select an app or website to give it its own settings.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 320)
        }
    }

    private func addDomain() {
        var host = newDomain.trimmingCharacters(in: .whitespaces).lowercased()
        if let parsed = URL(string: host)?.host { host = parsed }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        guard !host.isEmpty else { return }
        settings.prefs.domains[host, default: DomainOverride()] = settings.prefs.domains[host] ?? DomainOverride()
        selection = "site:" + host
        newDomain = ""
    }

    private func appDetail(_ bundleID: String) -> some View {
        let app = Binding(
            get: { settings.prefs.apps[bundleID] ?? AppOverride() },
            set: { settings.prefs.apps[bundleID] = $0 == AppOverride() ? nil : $0 })
        return Form {
            Section(Self.name(for: bundleID)) {
                triState("Completions", app.enabled)
                triState("Suggest in the middle of a line", app.midLine)
                Toggle("Leave the Tab key to this app", isOn: app.tabDisabled)
                Text("For apps where Tab matters, like indenting text or moving between form fields.").caption()
                Toggle("Learn from what I write here", isOn: app.recordWriting)
            }
            Section("Instructions for this app") {
                TextEditor(text: app.instructions).frame(minHeight: 60)
                Text("Added to your general instructions, e.g. “Short, casual replies”.").caption()
            }
            Section("Display") {
                LabeledContent("Text size: \(Int(app.wrappedValue.fontScale * 100))%") {
                    Slider(value: app.fontScale, in: 0.6...1.6, step: 0.05)
                }
                LabeledContent("Vertical offset: \(Int(app.wrappedValue.verticalOffset)) pt") {
                    Slider(value: app.verticalOffset, in: -12...12, step: 1)
                }
                Text("Adjust if suggestions look too big, too small, or misaligned in this app.").caption()
            }
            Section {
                Button("Reset to Defaults") { settings.prefs.apps[bundleID] = nil }
            }
        }
        .formStyle(.grouped)
    }

    private func domainDetail(_ domain: String) -> some View {
        let site = Binding(
            get: { settings.prefs.domains[domain] ?? DomainOverride() },
            set: { settings.prefs.domains[domain] = $0 })
        return Form {
            Section(domain) {
                triState("Completions", site.enabled)
            }
            Section("Instructions for this website") {
                TextEditor(text: site.instructions).frame(minHeight: 60)
            }
            Section {
                Button("Remove Website", role: .destructive) {
                    settings.prefs.domains[domain] = nil
                    selection = nil
                }
            }
        }
        .formStyle(.grouped)
    }

    private func triState(_ title: String, _ value: Binding<TriState>) -> some View {
        Picker(title, selection: value) {
            Text("Default").tag(TriState.inherit)
            Text("On").tag(TriState.on)
            Text("Off").tag(TriState.off)
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutsPane: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        Form {
            Section("Suggestions") {
                ShortcutRow(title: "Accept next word", shortcut: $settings.prefs.acceptWordShortcut)
                ShortcutRow(title: "Accept whole suggestion", shortcut: $settings.prefs.acceptAllShortcut)
                Text("These keys only act while a suggestion is visible; otherwise they work as usual.").caption()
            }
            Section("Anywhere") {
                ShortcutRow(title: "Toggle completions globally", shortcut: $settings.prefs.toggleGlobalShortcut)
                ShortcutRow(title: "Pause or resume in the current app", shortcut: $settings.prefs.toggleAppShortcut)
                ShortcutRow(title: "Show word alternatives", shortcut: $settings.prefs.alternativesShortcut)
                Text("Global shortcuts take the key combination away from other apps. Word alternatives are enabled under Labs.").caption()
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutRow: View {
    let title: String
    @Binding var shortcut: Shortcut?
    @ViewState private var recording = false
    @ViewState private var monitor: Any?
    @ViewState private var warning: String?

    var body: some View {
        VStack(alignment: .leading) {
            LabeledContent(title) {
                HStack {
                    Button(recording ? "Press keys…" : (shortcut?.label ?? "Record")) { recording ? stop() : start() }
                        .frame(minWidth: 90)
                    Button { shortcut = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).opacity(shortcut == nil ? 0 : 1)
                }
            }
            if let warning { Text(warning).font(.caption).foregroundStyle(.orange) }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        warning = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                stop()
            } else if let recorded = Shortcut(event: event) {
                if recorded.isTypingKey {
                    warning = "“\(recorded.label)” is a typing key; you could no longer type it while a suggestion is shown."
                }
                shortcut = recorded
                stop()
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - Emoji, battery, labs

private struct EmojiPane: View {
    @EnvironmentObject var settings: SettingsStore
    private let tones = ["👍", "👍🏻", "👍🏼", "👍🏽", "👍🏾", "👍🏿"]

    var body: some View {
        Form {
            Section {
                Toggle("Suggest emoji for shortcodes", isOn: $settings.prefs.emojiEnabled)
                Text("Type a colon and a name, like **:joy** or **:thumbsup**, then press \(settings.prefs.acceptWordShortcut?.label ?? "the accept key") to insert the emoji.").caption()
            }
            Section("Skin tone") {
                Picker("Preferred skin tone", selection: $settings.prefs.emojiSkinTone) {
                    ForEach(0..<tones.count, id: \.self) { Text(tones[$0]).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Used for hands and people where the emoji comes in several skin tones.").caption()
            }
        }
        .formStyle(.grouped)
    }
}

private struct BatteryPane: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        Form {
            Section("On battery power") {
                Toggle("Use shorter completions", isOn: $settings.prefs.shorterOnBattery)
                Text("Fewer words per suggestion means less work for the model and less energy used.").caption()
                Toggle("Pause completions entirely", isOn: $settings.prefs.pauseOnBattery)
            }
            Section {
                Text("Switching to a smaller model under AI Model saves the most energy, though suggestions get less accurate.").caption()
            }
        }
        .formStyle(.grouped)
    }
}

private struct LabsPane: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        Form {
            Section("Word alternatives") {
                Toggle("Offer word alternatives", isOn: $settings.prefs.wordAlternatives)
                Text("Select a word and Typist lists other words that fit the sentence. Without a selection, the shortcut lists alternatives to the word Typist would suggest next. Press the number next to one to use it.").caption()
                Toggle("Show automatically after selecting a word", isOn: $settings.prefs.autoShowAlternatives).disabled(!settings.prefs.wordAlternatives)
                ShortcutRow(title: "Show alternatives now", shortcut: $settings.prefs.alternativesShortcut).disabled(!settings.prefs.wordAlternatives)
            }
            Section {
                Text("Labs features are experimental and may change.").caption()
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Statistics

private struct StatisticsPane: View {
    @EnvironmentObject var stats: FileStore<UsageStats>
    @ViewState private var confirmReset = false

    var body: some View {
        let recent = stats.value.recent(14)
        let today = stats.value.day()
        Form {
            Section("Today") {
                LabeledContent("Words completed", value: "\(today.wordsCompleted)")
                LabeledContent("Suggestions accepted", value: "\(today.accepted) of \(today.shown) shown")
                LabeledContent("Keystrokes saved", value: "\(today.charactersSaved)")
            }
            Section("Last 14 days") {
                Chart(recent, id: \.date) { entry in
                    BarMark(x: .value("Day", entry.date, unit: .day), y: .value("Words", entry.day.wordsCompleted))
                }
                .frame(height: 160)
            }
            Section("All time") {
                LabeledContent("Words completed", value: "\(stats.value.totalWords)")
                let shown = stats.value.totalShown
                LabeledContent("Acceptance rate", value: shown == 0 ? "—" : "\(Int(Double(stats.value.totalAccepted) / Double(shown) * 100))%")
                Button("Reset Statistics…", role: .destructive) { confirmReset = true }
                    .confirmationDialog("Reset all statistics?", isPresented: $confirmReset) {
                        Button("Reset", role: .destructive) { stats.value = UsageStats() }
                    }
                Text("Statistics are counts only, kept on this Mac.").caption()
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About

private struct AboutPane: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Typist", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                Text("Open-source inline autocomplete for macOS. Runs entirely on your Mac.")
                Text("MIT License. Uses llama.cpp (MIT). Models have their own licenses.").caption()
            }
            Section("Privacy") {
                Text("Typist makes no network connections except to download a model you choose. It has no analytics, no accounts, and no cloud service. Settings, statistics and recorded writing live in ~/Library/Application Support/Typist.")
                Button("Open Data Folder") { NSWorkspace.shared.open(AppPaths.support) }
            }
        }
        .formStyle(.grouped)
    }
}

private extension Text {
    func caption() -> some View {
        font(.caption).foregroundStyle(.secondary)
    }
}
