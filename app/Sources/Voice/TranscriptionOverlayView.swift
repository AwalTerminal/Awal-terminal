import AppKit

/// Floating overlay panel that shows live transcription text above the status bar.
class TranscriptionOverlayView {

    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private let prefixLabel = NSTextField(labelWithString: "")
    private var dismissTimer: Timer?

    private let panelHeight: CGFloat = 36
    private let padding: CGFloat = 12

    /// Show transcription text in the overlay.
    func showTranscription(_ text: String, isCommand: Bool, in window: NSWindow) {
        dismissTimer?.invalidate()

        let overlay = panel ?? createPanel(in: window)
        positionPanel(overlay, in: window)

        prefixLabel.stringValue = isCommand ? "[Command]" : "[Dictation]"
        prefixLabel.textColor = isCommand
            ? NSColor(red: 120.0/255.0, green: 220.0/255.0, blue: 120.0/255.0, alpha: 1.0)
            : NSColor(red: 180.0/255.0, green: 180.0/255.0, blue: 255.0/255.0, alpha: 1.0)

        label.stringValue = text

        overlay.orderFrontRegardless()
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
        panel?.orderOut(nil)
    }

    // MARK: - Private

    private func createPanel(in window: NSWindow) -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: panelHeight),
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.hasShadow = true
        p.hidesOnDeactivate = false

        // Background view with rounded corners
        let bgView = NSView()
        bgView.wantsLayer = true
        bgView.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.9).cgColor
        bgView.layer?.cornerRadius = 8
        bgView.translatesAutoresizingMaskIntoConstraints = false
        p.contentView?.addSubview(bgView)

        let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        prefixLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        prefixLabel.translatesAutoresizingMaskIntoConstraints = false
        prefixLabel.setContentHuggingPriority(.required, for: .horizontal)
        bgView.addSubview(prefixLabel)

        label.font = monoFont
        label.textColor = NSColor(white: 0.9, alpha: 1)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        bgView.addSubview(label)

        NSLayoutConstraint.activate([
            bgView.leadingAnchor.constraint(equalTo: p.contentView!.leadingAnchor),
            bgView.trailingAnchor.constraint(equalTo: p.contentView!.trailingAnchor),
            bgView.topAnchor.constraint(equalTo: p.contentView!.topAnchor),
            bgView.bottomAnchor.constraint(equalTo: p.contentView!.bottomAnchor),

            prefixLabel.leadingAnchor.constraint(equalTo: bgView.leadingAnchor, constant: padding),
            prefixLabel.centerYAnchor.constraint(equalTo: bgView.centerYAnchor),

            label.leadingAnchor.constraint(equalTo: prefixLabel.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: bgView.trailingAnchor, constant: -padding),
            label.centerYAnchor.constraint(equalTo: bgView.centerYAnchor),
        ])

        self.panel = p
        return p
    }

    private func positionPanel(_ panel: NSPanel, in window: NSWindow) {
        let windowFrame = window.frame
        let statusBarHeight: CGFloat = StatusBarView.barHeight
        let margin: CGFloat = 8

        let x = windowFrame.origin.x + 20
        let y = windowFrame.origin.y + statusBarHeight + margin
        let width = min(windowFrame.width - 40, 500)

        panel.setFrame(NSRect(x: x, y: y, width: width, height: panelHeight), display: true)
    }
}
