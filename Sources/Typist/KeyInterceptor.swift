import CoreGraphics
import Foundation
import TypistCore

struct KeyEvent {
    var keyCode: Int64
    var flags: CGEventFlags
    /// Characters this key press would type.
    var characters: String

    /// Modifier bits as used by `Shortcut`.
    var modifiers: Int {
        var result = 0
        if flags.contains(.maskCommand) { result |= Shortcut.command }
        if flags.contains(.maskAlternate) { result |= Shortcut.option }
        if flags.contains(.maskControl) { result |= Shortcut.control }
        if flags.contains(.maskShift) { result |= Shortcut.shift }
        return result
    }

    func matches(_ shortcut: Shortcut?) -> Bool {
        shortcut?.matches(keyCode: Int(keyCode), modifiers: modifiers) ?? false
    }
}

enum InputEvent {
    case key(KeyEvent)
    case mouseDown
    case mouseUp
}

/// Session-wide event tap. Lets the app see key presses before the focused app
/// does and swallow the ones used to accept or dismiss a suggestion.
final class KeyInterceptor {
    /// Marks events posted by Typist itself so the tap ignores them.
    static let syntheticMarker: Int64 = 0x54595053 // "TYPS"

    /// Return `true` to swallow the event. Called on the main thread.
    var handler: (InputEvent) -> Bool = { _ in false }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    /// Fails when Accessibility permission has not been granted.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask: CGEventMask =
            1 << CGEventType.keyDown.rawValue
            | 1 << CGEventType.leftMouseDown.rawValue
            | 1 << CGEventType.rightMouseDown.rawValue
            | 1 << CGEventType.leftMouseUp.rawValue
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let interceptor = Unmanaged<KeyInterceptor>.fromOpaque(refcon!).takeUnretainedValue()
            return interceptor.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        case .leftMouseDown, .rightMouseDown:
            _ = handler(.mouseDown)
            return false
        case .leftMouseUp:
            _ = handler(.mouseUp)
            return false
        case .keyDown:
            // Events Typist posted itself (accepted text). Some apps' event
            // handling drops the marker, so also check who posted the event.
            if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker
                || event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) { return false }
            var length = 0
            var buffer = [UniChar](repeating: 0, count: 8)
            event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
            let key = KeyEvent(
                keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                flags: event.flags,
                characters: String(utf16CodeUnits: buffer, count: length))
            return handler(.key(key))
        default:
            return false
        }
    }
}
