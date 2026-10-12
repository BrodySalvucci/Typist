import AppKit
import IOKit.ps
import ServiceManagement
import TypistCore

/// Diagnostic log, off by default. Enable with
/// `defaults write org.typist.Typist debugLog -bool YES` and read
/// ~/Library/Logs/Typist.log. Never contains what you type, only lengths.
enum Log {
    static let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Typist.log")
    static let enabled = UserDefaults.standard.bool(forKey: "debugLog")
    private static let handle: FileHandle? = {
        guard enabled else { return nil }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try? FileHandle(forWritingTo: url)
    }()

    static func debug(_ message: @autoclosure () -> String) {
        guard let handle else { return }
        let line = String(format: "%.3f ", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 100_000)) + message() + "\n"
        handle.write(Data(line.utf8))
    }
}

enum PowerSource {
    static var isOnBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Typist: could not change login item: \(error.localizedDescription)")
        }
    }
}

/// Catches a typo in the word the user just finished, using the system spell checker.
enum TypoChecker {
    struct Fix {
        /// Characters to delete before the caret (the word and the separator after it).
        var deleteCount: Int
        var replacement: String
        var original: String
        var corrected: String
    }

    static func fix(for before: String) -> Fix? {
        guard let (word, separator) = TextAnalysis.justCompletedWord(in: before) else { return nil }
        let checker = NSSpellChecker.shared
        let range = NSRange(location: 0, length: (word as NSString).length)
        guard checker.checkSpelling(of: word, startingAt: 0).location != NSNotFound,
              let corrected = checker.correction(forWordRange: range, in: word, language: checker.language(), inSpellDocumentWithTag: 0),
              corrected != word else { return nil }
        return Fix(deleteCount: word.count + 1, replacement: corrected + String(separator), original: word, corrected: corrected)
    }
}

extension Shortcut {
    /// Builds a shortcut from a key press in the shortcut recorder.
    init?(event: NSEvent) {
        var modifiers = 0
        var label = ""
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control) { modifiers |= Shortcut.control; label += "⌃" }
        if flags.contains(.option) { modifiers |= Shortcut.option; label += "⌥" }
        if flags.contains(.shift) { modifiers |= Shortcut.shift; label += "⇧" }
        if flags.contains(.command) { modifiers |= Shortcut.command; label += "⌘" }

        let special: [UInt16: String] = [
            48: "⇥", 36: "↩", 49: "Space", 53: "⎋", 51: "⌫", 123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        if let name = special[event.keyCode] {
            label += name
        } else if let characters = event.charactersIgnoringModifiers?.uppercased(), !characters.isEmpty {
            label += characters
        } else {
            return nil
        }
        self.init(keyCode: Int(event.keyCode), modifiers: modifiers, label: label)
    }

    /// Plain typing keys make poor shortcuts: they would stop being typeable.
    var isTypingKey: Bool {
        modifiers & (Shortcut.command | Shortcut.control | Shortcut.option) == 0 && ![48, 53, 36].contains(keyCode) && !(96...126).contains(keyCode)
    }
}
