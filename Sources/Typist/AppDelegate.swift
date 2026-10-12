import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI
import TypistCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let state = AppState.shared
    private lazy var coordinator = CompletionCoordinator()

    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var permissionTimer: Timer?
    private var subscriptions: Set<AnyCancellable> = []
    /// The app that was frontmost when the menu opened (the menu itself does not activate Typist).
    private var menuTargetApp: NSRunningApplication?

    private var prefs: Preferences { state.prefs }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        state.loadActiveModel()
        state.refreshPersonalization()
        startWhenTrusted()
        observeState()

        // `--settings <pane>` opens Settings on a given pane (handy for scripting and screenshots).
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--settings"), arguments.indices.contains(flag + 1),
           let pane = SettingsPane(rawValue: arguments[flag + 1]) {
            showSettings(pane: pane)
        } else if !prefs.onboardingDone || !AccessibilityReader.isTrusted || state.models.installed.isEmpty {
            showSettings(pane: .setup)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.flush()
        state.stats.saveNow()
        state.samples.saveNow()
        state.engine.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(pane: nil)
        return false
    }

    // MARK: - Setup

    /// The event tap can only be created once Accessibility access is granted,
    /// so keep polling until the user has flipped the switch.
    private func startWhenTrusted() {
        if coordinator.start() { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            if self?.coordinator.start() == true { timer.invalidate() }
        }
    }

    private func observeState() {
        let prefs = state.settings.$prefs
        prefs.map(\.selectedModel).removeDuplicates().dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.state.loadActiveModel() } }
            .store(in: &subscriptions)
        prefs.map { [$0.recordWriting ? 1 : 0, $0.personalizationStrength] }.removeDuplicates().dropFirst()
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.state.refreshPersonalization() }
            .store(in: &subscriptions)

        // Anything that changes what the status item shows.
        Publishers.MergeMany(
            prefs.map { _ in () }.eraseToAnyPublisher(),
            state.stats.$value.map { _ in () }.eraseToAnyPublisher(),
            state.models.$progress.map { _ in () }.eraseToAnyPublisher(),
            state.models.$downloading.map { _ in () }.eraseToAnyPublisher(),
            state.pause.objectWillChange.eraseToAnyPublisher(),
            state.engineStatus.$phase.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.updateStatusItem() }
        .store(in: &subscriptions)
        updateStatusItem()
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let off = !prefs.enabled || state.pause.globalRemaining != nil || state.engineStatus.phase != .ready
        button.image = NSImage(systemSymbolName: "character.cursor.ibeam", accessibilityDescription: "Typist")
        button.appearsDisabled = off

        if state.models.downloading != nil {
            button.title = " \(Int(state.models.progress * 100))%"
        } else if prefs.showWordCountInMenuBar {
            button.title = " \(state.stats.value.day().wordsCompleted)"
        } else {
            button.title = ""
        }
    }

    // MARK: - Settings window

    func showSettings(pane: SettingsPane?) {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Typist Settings"
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        let view = SettingsView(initialPane: pane ?? .general)
            .environmentObject(state.settings)
            .environmentObject(state.models)
            .environmentObject(state.stats)
            .environmentObject(state.samples)
            .environmentObject(state.engineStatus)
        if pane != nil || settingsWindow?.contentViewController == nil {
            settingsWindow?.contentViewController = NSHostingController(rootView: view)
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menuTargetApp = NSWorkspace.shared.frontmostApplication
        let pause = state.pause

        if !AccessibilityReader.isTrusted {
            menu.addItem(item("Grant Accessibility Access…", #selector(openSetup)))
            menu.addItem(.separator())
        }
        if IsSecureEventInputEnabled() {
            menu.addItem(info("Secure Input is on — completions are paused"))
            menu.addItem(info("Usually a password field or password manager. Quit that app or lock and unlock your Mac."))
            menu.addItem(.separator())
        }
        switch state.engineStatus.phase {
        case .noModel:
            menu.addItem(item(state.models.downloading == nil ? "No Model Installed — Choose One…" : "Downloading model… \(Int(state.models.progress * 100))%", #selector(openModels)))
            menu.addItem(.separator())
        case .loading:
            menu.addItem(info("Loading model…"))
            menu.addItem(.separator())
        case .failed(let message):
            menu.addItem(item("Model failed to load: \(message)", #selector(openModels)))
            menu.addItem(.separator())
        case .ready:
            break
        }

        menu.addItem(item("Enable Completions", #selector(toggleEnabled), checked: prefs.enabled))
        if let remaining = pause.globalRemaining {
            menu.addItem(item("Resume Now (paused for \(Self.format(remaining)))", #selector(resumeGlobal)))
        } else {
            menu.addItem(item("Pause for \(prefs.pauseMinutes) Minutes", #selector(pauseGlobal)))
        }

        if let app = menuTargetApp, let bundleID = app.bundleIdentifier, bundleID != Bundle.main.bundleIdentifier {
            let name = app.localizedName ?? bundleID
            let override = prefs.app(bundleID)
            menu.addItem(.separator())
            menu.addItem(info(name))
            let enabledHere = override.enabled.resolved(default: prefs.enabledByDefault)
            menu.addItem(item("Completions in \(name)", #selector(toggleCurrentApp), checked: enabledHere))
            if pause.isPaused(app: bundleID), pause.globalRemaining == nil {
                let suffix = pause.appRemaining(bundleID).map { " (paused for \(Self.format($0)))" } ?? " (off until you switch apps)"
                menu.addItem(item("Resume in \(name)" + suffix, #selector(togglePauseCurrentApp)))
            } else if enabledHere {
                menu.addItem(item("Pause in \(name) for \(prefs.pauseMinutes) Minutes", #selector(togglePauseCurrentApp)))
            }
            menu.addItem(item("Leave Tab Key to \(name)", #selector(toggleTabCurrentApp), checked: override.tabDisabled))
            if let domain = coordinator.lastDomain {
                menu.addItem(item("Completions on \(domain)", #selector(toggleCurrentDomain), checked: prefs.isEnabled(onDomain: domain)))
            }
        }

        menu.addItem(.separator())
        let today = state.stats.value.day()
        menu.addItem(info("\(today.wordsCompleted) words completed today"))
        menu.addItem(item("Show Word Count in Menu Bar", #selector(toggleWordCount), checked: prefs.showWordCountInMenuBar))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(item("Quit Typist", #selector(NSApplication.terminate(_:)), target: NSApp, key: "q"))
    }

    private static func format(_ interval: TimeInterval) -> String {
        interval >= 60 ? "\(Int((interval / 60).rounded(.up))) min" : "\(Int(interval)) s"
    }

    private func item(_ title: String, _ action: Selector, target: AnyObject? = nil, checked: Bool = false, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target ?? self
        item.state = checked ? .on : .off
        return item
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Actions

    @objc private func openSetup() { showSettings(pane: .setup) }
    @objc private func openModels() { showSettings(pane: .model) }
    @objc private func openSettings() { showSettings(pane: nil) }

    @objc private func toggleEnabled() { state.settings.prefs.enabled.toggle() }
    @objc private func toggleWordCount() { state.settings.prefs.showWordCountInMenuBar.toggle() }
    @objc private func pauseGlobal() { state.pause.pauseGlobally(for: TimeInterval(prefs.pauseMinutes * 60)) }
    @objc private func resumeGlobal() { state.pause.resumeGlobally() }

    @objc private func toggleCurrentApp() {
        guard let bundleID = menuTargetApp?.bundleIdentifier else { return }
        let enabledHere = prefs.app(bundleID).enabled.resolved(default: prefs.enabledByDefault)
        state.settings.prefs.apps[bundleID, default: AppOverride()].enabled = enabledHere ? .off : .on
    }

    @objc private func togglePauseCurrentApp() {
        guard let bundleID = menuTargetApp?.bundleIdentifier else { return }
        coordinator.togglePause(app: bundleID)
    }

    @objc private func toggleTabCurrentApp() {
        guard let bundleID = menuTargetApp?.bundleIdentifier else { return }
        state.settings.prefs.apps[bundleID, default: AppOverride()].tabDisabled.toggle()
    }

    @objc private func toggleCurrentDomain() {
        guard let domain = coordinator.lastDomain else { return }
        let enabled = prefs.isEnabled(onDomain: domain)
        state.settings.prefs.domains[domain, default: DomainOverride()].enabled = enabled ? .off : .on
    }
}
