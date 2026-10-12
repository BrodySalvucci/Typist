import AppKit

/// A click-through window that draws suggestions over whatever app is focused.
final class SuggestionOverlay {
    enum Style {
        /// Grey text continuing the line, no background.
        case ghost
        /// A small rounded card: used for replacements and pickers.
        case card
    }

    private let panel: NSPanel
    private let background = NSView()
    private let label = NSTextField(labelWithString: "")
    private let inset = CGSize(width: 7, height: 4)

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        background.layer?.borderWidth = 0.5
        label.lineBreakMode = .byClipping
        background.addSubview(label)
        panel.contentView = background
    }

    var isVisible: Bool { panel.isVisible }

    /// Ghost text starting at the caret.
    /// - Parameters:
    ///   - caret: Caret rectangle in AppKit screen coordinates.
    ///   - fontScale: Per-app correction for apps whose line height misleads.
    func showGhost(_ text: String, at caret: CGRect, fontScale: Double = 1, verticalOffset: Double = 0) {
        // The host app's font is unknown; the caret height is a good proxy for its line height.
        let fontSize = min(max((caret.height * 0.78 * fontScale).rounded(), 9), 48)
        label.font = .systemFont(ofSize: fontSize)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 1
        label.stringValue = text
        apply(style: .ghost)

        var size = label.fittingSize
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(caret.origin) }) {
            size.width = min(size.width, max(screen.frame.maxX - caret.minX, 0))
        }
        label.frame = CGRect(origin: .zero, size: size)
        present(CGRect(x: caret.minX, y: caret.midY - size.height / 2 + verticalOffset, width: size.width, height: size.height))
    }

    /// A card just below `anchor` (the caret or a selection).
    func showCard(_ text: NSAttributedString, below anchor: CGRect) {
        label.maximumNumberOfLines = 0
        label.attributedStringValue = text
        apply(style: .card)

        let textSize = label.fittingSize
        let size = CGSize(width: textSize.width + inset.width * 2, height: textSize.height + inset.height * 2)
        label.frame = CGRect(x: inset.width, y: inset.height, width: textSize.width, height: textSize.height)

        var origin = CGPoint(x: anchor.minX, y: anchor.minY - size.height - 3)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor.origin) }) {
            if origin.y < screen.visibleFrame.minY { origin.y = anchor.maxY + 3 }
            origin.x = min(origin.x, screen.visibleFrame.maxX - size.width)
        }
        present(CGRect(origin: origin, size: size))
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func apply(style: Style) {
        let card = style == .card
        panel.hasShadow = card
        background.layer?.backgroundColor = card ? NSColor.windowBackgroundColor.cgColor : nil
        background.layer?.borderColor = card ? NSColor.separatorColor.cgColor : nil
        background.layer?.borderWidth = card ? 0.5 : 0
    }

    private func present(_ frame: CGRect) {
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }
}
