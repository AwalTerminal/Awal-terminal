import AppKit

/// Inline banner that appears above the status bar when a plan title is detected.
/// Offers to rename the tab/session to the plan title.
class PlanRenameBannerView: NSView {

    var onRename: (() -> Void)?

    private var dismissTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - Setup

    private func setupView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.95).cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor(white: 1.0, alpha: 0.12).cgColor
    }

    func configure(title: String) {
        // Icon
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "pencil.and.outline", accessibilityDescription: "Plan")
        icon.contentTintColor = NSColor(red: 180.0/255.0, green: 160.0/255.0, blue: 255.0/255.0, alpha: 1.0)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(icon)

        // Message label — truncate long titles
        let displayTitle = title.count > 60 ? String(title.prefix(57)) + "..." : title
        let messageLabel = NSTextField(labelWithString: "Plan: \(displayTitle)")
        messageLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        messageLabel.textColor = NSColor(white: 0.9, alpha: 1)
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(messageLabel)

        // Rename Tab button
        let ctaButton = NSButton(title: "Rename Tab", target: self, action: #selector(renameTapped))
        ctaButton.bezelStyle = .recessed
        ctaButton.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        ctaButton.contentTintColor = NSColor(red: 100.0/255.0, green: 180.0/255.0, blue: 255.0/255.0, alpha: 1.0)
        ctaButton.translatesAutoresizingMaskIntoConstraints = false
        ctaButton.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(ctaButton)

        // Close button
        let closeButton = NSButton(title: "", target: self, action: #selector(closeTapped))
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        closeButton.bezelStyle = .recessed
        closeButton.isBordered = false
        closeButton.contentTintColor = NSColor(white: 0.5, alpha: 1.0)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),

            messageLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            ctaButton.leadingAnchor.constraint(greaterThanOrEqualTo: messageLabel.trailingAnchor, constant: 12),
            ctaButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            closeButton.leadingAnchor.constraint(equalTo: ctaButton.trailingAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    // MARK: - Show / Dismiss

    func showAnimated() {
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            self.animator().alphaValue = 1.0
        }
        startAutoDismissTimer()
    }

    func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.removeFromSuperview()
        })
    }

    // MARK: - Private

    private func startAutoDismissTimer() {
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
    }

    @objc private func renameTapped() {
        onRename?()
        dismiss()
    }

    @objc private func closeTapped() {
        dismiss()
    }
}
