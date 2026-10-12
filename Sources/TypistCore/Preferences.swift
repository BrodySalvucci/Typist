import Foundation

/// A key combination. Modifier bits are Typist's own, independent of AppKit/CoreGraphics.
public struct Shortcut: Codable, Equatable, Hashable {
    public static let command = 1, option = 2, control = 4, shift = 8

    public var keyCode: Int
    public var modifiers: Int
    /// Human readable, e.g. "⇧⇥".
    public var label: String

    public init(keyCode: Int, modifiers: Int = 0, label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }

    public func matches(keyCode: Int, modifiers: Int) -> Bool {
        self.keyCode == keyCode && self.modifiers == modifiers
    }

    public static let tab = Shortcut(keyCode: 48, label: "⇥")
    public static let shiftTab = Shortcut(keyCode: 48, modifiers: shift, label: "⇧⇥")
}

public enum EscapeBehavior: String, Codable, CaseIterable {
    /// Hide the current suggestion only.
    case dismiss
    /// Also pause completions for a few seconds.
    case pauseBriefly
    /// Also turn completions off in this app until the user switches apps.
    case offUntilAppSwitch
}

public enum TriState: String, Codable, CaseIterable {
    case inherit, on, off

    public func resolved(default value: Bool) -> Bool {
        switch self {
        case .inherit: return value
        case .on: return true
        case .off: return false
        }
    }
}

/// Settings for one app (keyed by bundle identifier).
public struct AppOverride: Codable, Equatable {
    public var enabled = TriState.inherit
    public var midLine = TriState.inherit
    /// Leave Tab to the app (indenting, switching form fields).
    public var tabDisabled = false
    public var instructions = ""
    public var fontScale = 1.0
    public var verticalOffset = 0.0
    public var recordWriting = true

    public init() {}
}

/// Settings for one website (keyed by host name).
public struct DomainOverride: Codable, Equatable {
    public var enabled = TriState.inherit
    public var instructions = ""

    public init() {}
}

public struct Preferences: Codable, Equatable {
    // General
    public var enabled = true
    /// When off, completions only run in apps that are individually enabled.
    public var enabledByDefault = true
    public var maxWords = 8
    public var allowMidLine = false
    public var smallFields = false
    /// 0 = only very sure suggestions, 1 = suggest eagerly.
    public var eagerness = 0.5
    public var acceptTrailingSpace = false
    public var acceptAttachedPunctuation = true
    public var escapeBehavior = EscapeBehavior.dismiss
    public var pauseMinutes = 5
    public var showWordCountInMenuBar = false
    public var onboardingDone = false

    // Model
    public var selectedModel: String?

    // Context
    public var useWindowContext = true
    public var useScreenContext = false
    public var useClipboardContext = false

    // Personalization
    public var instructions = ""
    public var recordWriting = false
    public var personalizationStrength = 0.3

    // Per-app / per-site
    public var apps: [String: AppOverride] = [:]
    public var domains: [String: DomainOverride] = [:]

    // Shortcuts
    public var acceptWordShortcut: Shortcut? = .tab
    public var acceptAllShortcut: Shortcut? = .shiftTab
    public var toggleGlobalShortcut: Shortcut?
    public var toggleAppShortcut: Shortcut?
    public var alternativesShortcut: Shortcut?

    // Emoji
    public var emojiEnabled = true
    /// 0 = default yellow, 1...5 = light to dark.
    public var emojiSkinTone = 0

    // Typos
    public var typoDetection = true
    public var showTypoFixes = true

    // Battery
    public var shorterOnBattery = true
    public var pauseOnBattery = false

    // Labs
    public var wordAlternatives = false
    public var autoShowAlternatives = false

    public init() {}

    /// Decodes stored preferences, filling in defaults for anything missing so
    /// that settings survive app updates that add new fields.
    public static func decode(from data: Data) -> Preferences {
        guard let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return Preferences() }
        var merged = merge(defaults: jsonObject(Preferences()), stored: stored)
        merged["apps"] = mergeEntries(stored["apps"], defaults: jsonObject(AppOverride()))
        merged["domains"] = mergeEntries(stored["domains"], defaults: jsonObject(DomainOverride()))
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged),
              let preferences = try? JSONDecoder().decode(Preferences.self, from: mergedData) else { return Preferences() }
        return preferences
    }

    public func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    public func app(_ bundleID: String?) -> AppOverride {
        bundleID.flatMap { apps[$0] } ?? AppOverride()
    }

    public func isEnabled(inApp bundleID: String?) -> Bool {
        enabled && app(bundleID).enabled.resolved(default: enabledByDefault)
    }

    public func isEnabled(onDomain host: String?) -> Bool {
        host.flatMap { domains[$0] }?.enabled.resolved(default: true) ?? true
    }

    private static func jsonObject<T: Encodable>(_ value: T) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    private static func merge(defaults: [String: Any], stored: [String: Any]) -> [String: Any] {
        defaults.merging(stored) { _, new in new }
    }

    private static func mergeEntries(_ stored: Any?, defaults: [String: Any]) -> [String: Any] {
        guard let entries = stored as? [String: Any] else { return [:] }
        return entries.compactMapValues { ($0 as? [String: Any]).map { merge(defaults: defaults, stored: $0) } }
    }
}
