import AppKit

/// Inline banner that appears above the status bar when auto-sync detects AI component changes.
/// Embedded as a plain NSView in the window's content view hierarchy (no NSPanel).
class SyncChangeBannerView: NSView {

    var onViewChanges: (() -> Void)?

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

    func configure(summary: SyncChangeSummary) {
        // Icon
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Sync")
        icon.contentTintColor = NSColor(red: 120.0/255.0, green: 220.0/255.0, blue: 120.0/255.0, alpha: 1.0)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(icon)

        // Message label
        let message = buildMessage(summary)
        let messageLabel = NSTextField(labelWithString: message)
        messageLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        messageLabel.textColor = NSColor(white: 0.9, alpha: 1)
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(messageLabel)

        // View Changes button
        let ctaButton = NSButton(title: "View Changes", target: self, action: #selector(viewChangesTapped))
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
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
    }

    private func buildMessage(_ summary: SyncChangeSummary) -> String {
        var parts: [String] = []
        if !summary.added.isEmpty {
            parts.append("\(summary.added.count) new")
        }
        if !summary.modified.isEmpty {
            parts.append("\(summary.modified.count) modified")
        }
        if !summary.removed.isEmpty {
            parts.append("\(summary.removed.count) removed")
        }
        if parts.isEmpty {
            return "AI components updated"
        }
        return "AI components updated — " + parts.joined(separator: ", ")
    }

    @objc private func viewChangesTapped() {
        onViewChanges?()
        dismiss()
    }

    @objc private func closeTapped() {
        dismiss()
    }
}
