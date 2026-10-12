import AppKit
import ApplicationServices

// Text-marker helpers live in ApplicationServices but are missing from its
// headers. Chromium, Electron and WebKit report caret geometry only through
// them. Create/Copy functions return an owned reference.
@_silgen_name("AXTextMarkerRangeCreate")
private func AXTextMarkerRangeCreate(_ allocator: CFAllocator?, _ start: CFTypeRef, _ end: CFTypeRef) -> CFTypeRef?
@_silgen_name("AXTextMarkerRangeCopyEndMarker")
private func AXTextMarkerRangeCopyEndMarker(_ range: CFTypeRef) -> CFTypeRef?

/// What is known about the focused text field at one moment.
struct FocusSnapshot {
    var before: String
    var after: String
    var hasSelection: Bool
    /// Caret rectangle in AppKit screen coordinates (origin bottom-left).
    var caretRect: CGRect?
    var selectedText = ""
    /// Bounds of the selection in AppKit screen coordinates.
    var selectionRect: CGRect?
    /// Size of the text field itself, when the app reports it.
    var fieldSize: CGSize?
    /// The text field's frame in AppKit screen coordinates.
    var fieldFrame: CGRect?
    var windowTitle: String?
    /// Placeholder text of the field, e.g. "Write a reply…".
    var placeholder: String?
    /// Host of the web page being edited, in browsers.
    var domain: String?
}

/// Reads the focused text field of the frontmost app through the Accessibility API.
enum AccessibilityReader {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Chromium and Electron apps only build their accessibility tree when asked.
    static func enableAccessibilityTree(for app: NSRunningApplication) {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// Why the last `snapshot()` returned nil; for the diagnostic log.
    private(set) static var lastFailure = ""

    /// Height of the primary display, captured on the main thread so that
    /// `snapshot` can run on a background queue.
    private static var primaryHeight: CGFloat = 0

    /// Reads the focused text field. Slow apps can take tens of milliseconds
    /// to answer, so call this off the main thread.
    /// - Parameter primaryScreenHeight: `NSScreen.screens[0].frame.height`.
    static func snapshot(primaryScreenHeight: CGFloat) -> FocusSnapshot? {
        primaryHeight = primaryScreenHeight
        guard let element = focusedElement() else {
            lastFailure = "no focused element"
            return nil
        }
        let role: String = attribute(element, kAXRoleAttribute) ?? "?"
        if let subrole: String = attribute(element, kAXSubroleAttribute), subrole == (kAXSecureTextFieldSubrole as String) {
            lastFailure = "secure field"
            return nil
        }
        guard let value: String = attribute(element, kAXValueAttribute) else {
            lastFailure = "focused \(role) has no text value"
            return nil
        }
        guard let range = selectedRange(of: element) else {
            lastFailure = "focused \(role) has no selection range"
            return nil
        }

        let text = value as NSString
        guard range.location >= 0, range.location + range.length <= text.length else {
            lastFailure = "selection range outside text"
            return nil
        }
        // Web content reports trailing spaces as non-breaking spaces.
        var snapshot = FocusSnapshot(
            before: text.substring(to: range.location).replacingOccurrences(of: "\u{00A0}", with: " "),
            after: text.substring(from: range.location + range.length).replacingOccurrences(of: "\u{00A0}", with: " "),
            hasSelection: range.length > 0,
            caretRect: caretRect(in: element, at: range.location + range.length, textLength: text.length)
        )
        if range.length > 0 {
            snapshot.selectedText = text.substring(with: NSRange(location: range.location, length: range.length))
            snapshot.selectionRect = bounds(in: element, location: range.location, length: range.length).map(flipped)
        }
        snapshot.fieldSize = size(of: element)
        if let size = snapshot.fieldSize, let origin = position(of: element) {
            snapshot.fieldFrame = flipped(CGRect(origin: origin, size: size))
        }
        if snapshot.caretRect == nil {
            snapshot.caretRect = markerCaretRect(in: element)
        }
        snapshot.placeholder = attribute(element, kAXPlaceholderValueAttribute)
        if let window: AXUIElement = attribute(element, kAXWindowAttribute) {
            snapshot.windowTitle = attribute(window, kAXTitleAttribute)
        }
        snapshot.domain = domain(containing: element)
        return snapshot
    }

    private static func size(of element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    private static func position(of element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    // MARK: Text markers (web content)

    private static func markerBounds(in element: AXUIElement, range: CFTypeRef) -> CGRect? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, "AXBoundsForTextMarkerRange" as CFString, range, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect), rect.height > 1 else { return nil }
        return rect
    }

    private static func marker(_ attribute: String, of marker: CFTypeRef, in element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, marker, &value) == .success else { return nil }
        return value
    }

    /// Caret rectangle from the selected text-marker range. An empty range
    /// often has no bounds, so fall back to the character before (or after) it.
    private static func markerCaretRect(in element: AXUIElement) -> CGRect? {
        var selection: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &selection) == .success,
              let selection else { return nil }
        var rect: CGRect?
        if let caret = markerBounds(in: element, range: selection) {
            rect = CGRect(x: caret.maxX, y: caret.minY, width: 0, height: caret.height)
        } else if let end = AXTextMarkerRangeCopyEndMarker(selection) {
            if let previous = marker("AXPreviousTextMarkerForTextMarker", of: end, in: element),
               let range = AXTextMarkerRangeCreate(nil, previous, end),
               let bounds = markerBounds(in: element, range: range) {
                rect = CGRect(x: bounds.maxX, y: bounds.minY, width: 0, height: bounds.height)
            } else if let next = marker("AXNextTextMarkerForTextMarker", of: end, in: element),
                      let range = AXTextMarkerRangeCreate(nil, end, next),
                      let bounds = markerBounds(in: element, range: range) {
                rect = CGRect(x: bounds.minX, y: bounds.minY, width: 0, height: bounds.height)
            }
        }
        return rect.map(flipped)
    }

    /// Walks up from a text field to the enclosing web area and returns its host.
    private static func domain(containing element: AXUIElement) -> String? {
        var current = element
        for _ in 0..<40 {
            if let role: String = attribute(current, kAXRoleAttribute), role == "AXWebArea" {
                let url: URL? = attribute(current, kAXURLAttribute)
                return url?.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
            }
            guard let parent: AXUIElement = attribute(current, kAXParentAttribute) else { return nil }
            current = parent
        }
        return nil
    }

    /// Accessibility uses a top-left origin on the primary display; AppKit a bottom-left one.
    private static func flipped(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    // MARK: - Private

    private static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
        if let element: AXUIElement = attribute(systemWide, kAXFocusedUIElementAttribute) {
            AXUIElementSetMessagingTimeout(element, 0.25)
            return element
        }
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        return attribute(appElement, kAXFocusedUIElementAttribute)
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }

    private static func bounds(in element: AXUIElement, location: Int, length: Int) -> CGRect? {
        var range = CFRange(location: location, length: length)
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &value) == .success,
            let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect), rect.height > 1 else { return nil }
        return rect
    }

    private static func caretRect(in element: AXUIElement, at location: Int, textLength: Int) -> CGRect? {
        var rect: CGRect?
        if let caret = bounds(in: element, location: location, length: 0) {
            rect = CGRect(x: caret.minX, y: caret.minY, width: 0, height: caret.height)
        } else if location > 0, let previous = bounds(in: element, location: location - 1, length: 1) {
            // Many apps return nothing for empty ranges; use the trailing edge
            // of the character before the caret instead.
            rect = CGRect(x: previous.maxX, y: previous.minY, width: 0, height: previous.height)
        }
        return rect.map(flipped)
    }
}
