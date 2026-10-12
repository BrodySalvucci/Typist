import CoreGraphics
import Foundation

/// Types text into the focused app by posting synthetic keyboard events that
/// carry the text as a Unicode string. Works in any app that accepts typing and
/// leaves the clipboard alone.
enum TextInserter {
    /// Longer strings are silently cut off by some apps.
    private static let chunkLength = 20

    /// Removes `count` characters before the caret, then types `text`.
    static func replace(last count: Int, with text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<count {
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: keyDown) else { continue }
                event.flags = []
                event.setIntegerValueField(.eventSourceUserData, value: KeyInterceptor.syntheticMarker)
                event.post(tap: .cgSessionEventTap)
            }
        }
        insert(text)
    }

    static func insert(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let units = Array(text.utf16)
        var start = 0
        while start < units.count {
            var end = min(start + chunkLength, units.count)
            // Don't split a surrogate pair across two events.
            if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
            let chunk = Array(units[start..<end])
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else { continue }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                event.setIntegerValueField(.eventSourceUserData, value: KeyInterceptor.syntheticMarker)
                event.post(tap: .cgSessionEventTap)
            }
            start = end
        }
    }
}
