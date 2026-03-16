import AppKit

class ScrollToBottomButton: NSView {

    var onScrollToBottom: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    private func setupView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.85).cgColor
        layer?.cornerRadius = 14
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor(white: 1.0, alpha: 0.12).cgColor

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Scroll to bottom")
        icon.contentTintColor = NSColor(white: 0.8, alpha: 1.0)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentHuggingPriority(.required, for: .vertical)
        addSubview(icon)

        let label = NSTextField(labelWithString: "Bottom")
        label.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        label.textColor = NSColor(white: 0.8, alpha: 1.0)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 12),
            icon.heightAnchor.constraint(equalToConstant: 12),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            heightAnchor.constraint(equalToConstant: 28),
        ])

        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = NSColor(white: 0.2, alpha: 0.85).cgColor
    }

    override func mouseUp(with event: NSEvent) {
        layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.85).cgColor
        let loc = convert(event.locationInWindow, from: nil)
        if bounds.contains(loc) {
            onScrollToBottom?()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor(white: 0.15, alpha: 0.85).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.85).cgColor
    }
}
