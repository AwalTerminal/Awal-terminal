import AppKit

class RemoteControlPopoverView: NSViewController {

    private let sessionURL: String

    init(url: String) {
        self.sessionURL = url
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 320))

        let titleLabel = NSTextField(labelWithString: "Remote Control")
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleLabel)

        let subtitleLabel = NSTextField(labelWithString: "Scan to connect from your phone")
        subtitleLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(subtitleLabel)

        let qrImageView = NSImageView()
        qrImageView.translatesAutoresizingMaskIntoConstraints = false
        qrImageView.imageScaling = .scaleProportionallyUpOrDown
        if let qrImage = generateQRCode(from: sessionURL) {
            qrImageView.image = qrImage
        }
        container.addSubview(qrImageView)

        let urlField = NSTextField(wrappingLabelWithString: sessionURL)
        urlField.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        urlField.textColor = .secondaryLabelColor
        urlField.isSelectable = true
        urlField.alignment = .center
        urlField.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(urlField)

        let copyButton = NSButton(title: "Copy URL", target: self, action: #selector(copyURL))
        copyButton.bezelStyle = .rounded
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(copyButton)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            titleLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            qrImageView.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 12),
            qrImageView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            qrImageView.widthAnchor.constraint(equalToConstant: 180),
            qrImageView.heightAnchor.constraint(equalToConstant: 180),

            urlField.topAnchor.constraint(equalTo: qrImageView.bottomAnchor, constant: 8),
            urlField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            urlField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            copyButton.topAnchor.constraint(equalTo: urlField.bottomAnchor, constant: 10),
            copyButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            copyButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
        ])

        self.view = container
    }

    @objc private func copyURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sessionURL, forType: .string)
    }

    private func generateQRCode(from string: String) -> NSImage? {
        guard let data = string.data(using: .utf8) else { return nil }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
