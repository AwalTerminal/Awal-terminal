import AppKit

class ZoomHUDView: NSView {

    private let label: NSTextField
    private var fadeTimer: Timer?

    override init(frame frameRect: NSRect) {
        label = NSTextField(labelWithString: "100%")
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    private func setupView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.85).cgColor
        layer?.cornerRadius = 10
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor(white: 1.0, alpha: 0.12).cgColor

        label.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .medium)
        label.textColor = NSColor(white: 0.85, alpha: 1.0)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 32),
        ])

        isHidden = true
        alphaValue = 0
    }

    func show(zoomPercent: Int) {
        label.stringValue = "\(zoomPercent)%"

        isHidden = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            self.animator().alphaValue = 1
        }

        fadeTimer?.invalidate()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                self.animator().alphaValue = 0
            }, completionHandler: {
                self.isHidden = true
            })
        }
    }
}
