import AppKit

/// Floating banner that appears when AI components are updated after a sync.
/// Shows a brief summary with a CTA to view detailed changes.
class SyncChangeBannerView: NSObject {

    private var panel: NSPanel?
    private var dismissTimer: Timer?
    private var isVisible = false
    private var onViewChanges: (() -> Void)?

    /// Show the sync change banner above the status bar.
    func show(summary: SyncChangeSummary, in window: NSWindow, onViewChanges: @escaping () -> Void) {
        dismiss()
        self.onViewChanges = onViewChanges

        let overlay = createPanel(summary: summary, in: window)
        positionPanel(overlay, in: window)

        overlay.alphaValue = 0
        overlay.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            overlay.animator().alphaValue = 1.0
        }
        isVisible = true

        // Auto-dismiss after 10 seconds
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
    }

    /// Dismiss the banner with fade-out animation.
    func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        guard let panel, isVisible else { return }
        let dismissingPanel = panel
        self.panel = nil
        self.isVisible = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            dismissingPanel.animator().alphaValue = 0
        }, completionHandler: {
            dismissingPanel.orderOut(nil)
        })
    }

    // MARK: - Private

    private func createPanel(summary: SyncChangeSummary, in window: NSWindow) -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 40),
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.hasShadow = true
        p.hidesOnDeactivate = false

        // Background view
        let bgView = NSView()
        bgView.wantsLayer = true
        bgView.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.9).cgColor
        bgView.layer?.cornerRadius = 8
        bgView.layer?.borderWidth = 0.5
        bgView.layer?.borderColor = NSColor(white: 1.0, alpha: 0.12).cgColor
        bgView.translatesAutoresizingMaskIntoConstraints = false
        p.contentView?.addSubview(bgView)

        // Icon
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Sync")
        icon.contentTintColor = NSColor(red: 120.0/255.0, green: 220.0/255.0, blue: 120.0/255.0, alpha: 1.0)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)
        bgView.addSubview(icon)

        // Message label
        let messageLabel = NSTextField(labelWithString: buildMessage(summary))
        messageLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        messageLabel.textColor = NSColor(white: 0.9, alpha: 1)
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bgView.addSubview(messageLabel)

        // View Changes button (CTA)
        let ctaButton = NSButton(title: "View Changes", target: self, action: #selector(viewChangesTapped))
        ctaButton.bezelStyle = .recessed
        ctaButton.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        ctaButton.contentTintColor = NSColor(red: 100.0/255.0, green: 180.0/255.0, blue: 255.0/255.0, alpha: 1.0)
        ctaButton.translatesAutoresizingMaskIntoConstraints = false
        ctaButton.setContentHuggingPriority(.required, for: .horizontal)
        bgView.addSubview(ctaButton)

        // Close button
        let closeButton = NSButton(title: "", target: self, action: #selector(closeTapped))
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        closeButton.bezelStyle = .recessed
        closeButton.isBordered = false
        closeButton.contentTintColor = NSColor(white: 0.5, alpha: 1.0)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setContentHuggingPriority(.required, for: .horizontal)
        bgView.addSubview(closeButton)

        NSLayoutConstraint.activate([
            bgView.leadingAnchor.constraint(equalTo: p.contentView!.leadingAnchor),
            bgView.trailingAnchor.constraint(equalTo: p.contentView!.trailingAnchor),
            bgView.topAnchor.constraint(equalTo: p.contentView!.topAnchor),
            bgView.bottomAnchor.constraint(equalTo: p.contentView!.bottomAnchor),

            icon.leadingAnchor.constraint(equalTo: bgView.leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: bgView.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),

            messageLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            messageLabel.centerYAnchor.constraint(equalTo: bgView.centerYAnchor),

            ctaButton.leadingAnchor.constraint(greaterThanOrEqualTo: messageLabel.trailingAnchor, constant: 12),
            ctaButton.centerYAnchor.constraint(equalTo: bgView.centerYAnchor),

            closeButton.leadingAnchor.constraint(equalTo: ctaButton.trailingAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: bgView.trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: bgView.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20),
        ])

        self.panel = p
        return p
    }

    private func positionPanel(_ panel: NSPanel, in window: NSWindow) {
        let windowFrame = window.frame
        let statusBarHeight: CGFloat = StatusBarView.barHeight
        let margin: CGFloat = 8

        let x = windowFrame.origin.x + 20
        let width = windowFrame.width - 40
        let height: CGFloat = 40
        let y = windowFrame.origin.y + statusBarHeight + margin
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
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
        dismiss()
        onViewChanges?()
    }

    @objc private func closeTapped() {
        dismiss()
    }
}
