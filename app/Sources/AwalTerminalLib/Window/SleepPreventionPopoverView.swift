import AppKit

class SleepPreventionPopoverView: NSViewController {

    private let isActive: Bool
    private let isRemoteControlLinked: Bool
    init(isActive: Bool, isRemoteControlLinked: Bool) {
        self.isActive = isActive
        self.isRemoteControlLinked = isRemoteControlLinked
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: isActive ? 160 : 120))

        let titleLabel = NSTextField(labelWithString: "Sleep Prevention")
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleLabel)

        // Status indicator
        let statusDot = NSView()
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 4
        statusDot.layer?.backgroundColor = isActive
            ? NSColor(red: 0.3, green: 0.85, blue: 0.4, alpha: 1.0).cgColor
            : NSColor(white: 0.4, alpha: 1.0).cgColor
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusDot)

        let statusText = isActive ? "Active — preventing display sleep" : "Inactive"
        let statusLabel = NSTextField(labelWithString: statusText)
        statusLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusLabel)

        // Info label about remote control
        let infoLabel = NSTextField(wrappingLabelWithString: "Automatically enabled during remote control sessions.")
        infoLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        infoLabel.textColor = NSColor.tertiaryLabelColor
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(infoLabel)

        var constraints = [
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),

            statusDot.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            statusDot.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            statusDot.widthAnchor.constraint(equalToConstant: 8),
            statusDot.heightAnchor.constraint(equalToConstant: 8),

            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 6),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            infoLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 14),
            infoLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            infoLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
        ]

        if isActive {
            let stealthButton = ActionButton(title: "Enter Stealth Mode") { [weak self] in
                self?.dismiss(nil)
                DispatchQueue.main.async {
                    StealthOverlayWindow.shared.activate()
                }
            }
            stealthButton.bezelStyle = .rounded
            stealthButton.controlSize = .regular
            stealthButton.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(stealthButton)

            constraints += [
                stealthButton.topAnchor.constraint(equalTo: infoLabel.bottomAnchor, constant: 14),
                stealthButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                stealthButton.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -16),
            ]
        } else {
            constraints.append(
                infoLabel.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -16)
            )
        }

        NSLayoutConstraint.activate(constraints)
        self.view = container
    }
}

/// Button that uses a closure instead of target/action — avoids weak-target issues in popovers.
private class ActionButton: NSButton {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        self.target = self
        self.action = #selector(clicked)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func clicked() {
        handler()
    }
}
