import AppKit

// MARK: - Theme

enum Theme {
    // Backgrounds
    static let windowBg = NSColor(red: 22.0/255.0, green: 22.0/255.0, blue: 22.0/255.0, alpha: 1)
    static let editorBg = NSColor(red: 30.0/255.0, green: 30.0/255.0, blue: 30.0/255.0, alpha: 1)

    // Accent & selection
    static let accent = NSColor(red: 45.0/255.0, green: 127.0/255.0, blue: 212.0/255.0, alpha: 1)
    static let accentSelection = NSColor(red: 45.0/255.0, green: 127.0/255.0, blue: 212.0/255.0, alpha: 0.15)
    static let barBorder = NSColor(white: 1, alpha: 0.06)
    static let textSelection = NSColor(red: 45.0/255.0, green: 127.0/255.0, blue: 212.0/255.0, alpha: 0.4)

    // Syntax colors
    static let stringColor = NSColor(red: 143.0/255.0, green: 217.0/255.0, blue: 143.0/255.0, alpha: 1)
    static let numberColor = NSColor(red: 217.0/255.0, green: 166.0/255.0, blue: 89.0/255.0, alpha: 1)
    static let boolColor = NSColor(red: 140.0/255.0, green: 166.0/255.0, blue: 242.0/255.0, alpha: 1)
    static let nullColor = NSColor(white: 0.35, alpha: 1)
    static let containerColor = NSColor(white: 0.45, alpha: 1)
    static let keyColor = NSColor.white

    // Text colors
    static let textPrimary = NSColor(white: 0.90, alpha: 1)
    static let textSecondary = NSColor(white: 0.60, alpha: 1)
    static let textTertiary = NSColor(white: 0.45, alpha: 1)

    // Surface colors
    static let separator = NSColor(white: 1, alpha: 0.08)
    static let surfaceHover = NSColor(white: 1, alpha: 0.06)
    static let surfacePressed = NSColor(white: 1, alpha: 0.10)

    // Semantic colors
    static let dangerColor = NSColor(red: 255.0/255.0, green: 153.0/255.0, blue: 0.0/255.0, alpha: 1)
    static let successColor = NSColor(red: 77.0/255.0, green: 217.0/255.0, blue: 102.0/255.0, alpha: 1)

    // Fonts
    static let monoFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let barFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    static let labelFont = NSFont.systemFont(ofSize: 13)
    static let smallFont = NSFont.systemFont(ofSize: 11)
    static let captionFont = NSFont.systemFont(ofSize: 10)
    static let headingFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
    static let monoSmall = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    // Spacing
    static let rowHeight: CGFloat = 32
    static let compactRowHeight: CGFloat = 28
    static let barHeight: CGFloat = 36
}

// MARK: - HoverButton

class HoverButton: NSButton {
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    var normalTint: NSColor = NSColor(white: 0.60, alpha: 1) {
        didSet { if !isHovered { contentTintColor = normalTint } }
    }
    var hoverTint: NSColor = NSColor(white: 0.90, alpha: 1)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        contentTintColor = hoverTint
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        contentTintColor = normalTint
    }
}
