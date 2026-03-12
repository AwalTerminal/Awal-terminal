import AppKit

/// Floating overlay panel that shows live transcription text above the status bar.
class TranscriptionOverlayView {

    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private let prefixLabel = NSTextField(labelWithString: "")
    private let micIcon = NSImageView()
    private var dismissTimer: Timer?
    private var isVisible = false

    private let minPanelHeight: CGFloat = 36
    private let maxPanelHeight: CGFloat = 200
    private let padding: CGFloat = 12

    /// Show transcription text in the overlay.
    func showTranscription(_ text: String, isCommand: Bool, in window: NSWindow) {
        dismissTimer?.invalidate()

        let overlay = panel ?? createPanel(in: window)

        prefixLabel.stringValue = isCommand ? "[Command]" : "[Dictation]"
        prefixLabel.textColor = isCommand
            ? NSColor(red: 120.0/255.0, green: 220.0/255.0, blue: 120.0/255.0, alpha: 1.0)
            : NSColor(red: 180.0/255.0, green: 180.0/255.0, blue: 255.0/255.0, alpha: 1.0)

        label.stringValue = text

        // Reposition after setting text so panel height adjusts to content
        positionPanel(overlay, in: window)

        if !isVisible {
            overlay.alphaValue = 0
            overlay.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                overlay.animator().alphaValue = 1.0
            }
            isVisible = true
        } else {
            overlay.orderFrontRegardless()
        }
    }

    /// Show final result and auto-dismiss after delay.
    func showFinalResult(_ text: String, isCommand: Bool, in window: NSWindow) {
        showTranscription(text, isCommand: isCommand, in: window)

        dismissTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
    }

    /// Dismiss the overlay.
    func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        guard let panel, isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            self?.isVisible = false
        })
    }

    // MARK: - Private

    private func createPanel(in window: NSWindow) -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: minPanelHeight),
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.hasShadow = true
        p.hidesOnDeactivate = false

        // Background view with rounded corners and subtle border
        let bgView = NSView()
        bgView.wantsLayer = true
        bgView.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.9).cgColor
        bgView.layer?.cornerRadius = 8
        bgView.layer?.borderWidth = 0.5
        bgView.layer?.borderColor = NSColor(white: 1.0, alpha: 0.12).cgColor
        bgView.translatesAutoresizingMaskIntoConstraints = false
        p.contentView?.addSubview(bgView)

        // Mic icon
        micIcon.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Microphone")
        micIcon.contentTintColor = NSColor(white: 0.5, alpha: 1.0)
        micIcon.translatesAutoresizingMaskIntoConstraints = false
        micIcon.setContentHuggingPriority(.required, for: .horizontal)
        bgView.addSubview(micIcon)

        let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        prefixLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        prefixLabel.translatesAutoresizingMaskIntoConstraints = false
        prefixLabel.setContentHuggingPriority(.required, for: .horizontal)
        bgView.addSubview(prefixLabel)

        label.font = monoFont
        label.textColor = NSColor(white: 0.9, alpha: 1)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 8
        label.cell?.wraps = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bgView.addSubview(label)

        NSLayoutConstraint.activate([
            bgView.leadingAnchor.constraint(equalTo: p.contentView!.leadingAnchor),
            bgView.trailingAnchor.constraint(equalTo: p.contentView!.trailingAnchor),
            bgView.topAnchor.constraint(equalTo: p.contentView!.topAnchor),
            bgView.bottomAnchor.constraint(equalTo: p.contentView!.bottomAnchor),

            micIcon.leadingAnchor.constraint(equalTo: bgView.leadingAnchor, constant: padding),
            micIcon.topAnchor.constraint(equalTo: bgView.topAnchor, constant: 8),
            micIcon.widthAnchor.constraint(equalToConstant: 14),
            micIcon.heightAnchor.constraint(equalToConstant: 14),

            prefixLabel.leadingAnchor.constraint(equalTo: micIcon.trailingAnchor, constant: 6),
            prefixLabel.topAnchor.constraint(equalTo: bgView.topAnchor, constant: 8),

            label.leadingAnchor.constraint(equalTo: prefixLabel.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: bgView.trailingAnchor, constant: -padding),
            label.topAnchor.constraint(equalTo: bgView.topAnchor, constant: 8),
            label.bottomAnchor.constraint(lessThanOrEqualTo: bgView.bottomAnchor, constant: -8),
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

        // Set preferred max layout width so text wrapping computes correctly
        label.preferredMaxLayoutWidth = width - padding * 2 - 14 - 6 - prefixLabel.intrinsicContentSize.width - 8

        // Compute dynamic height from content
        let fittingSize = panel.contentView?.fittingSize ?? NSSize(width: width, height: minPanelHeight)
        let height = min(max(fittingSize.height, minPanelHeight), maxPanelHeight)

        let y = windowFrame.origin.y + statusBarHeight + margin
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }
}
