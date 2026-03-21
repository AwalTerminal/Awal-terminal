import AppKit

class UpdateWindow: NSWindowController {

    private static var shared: UpdateWindow?

    private var release: UpdateChecker.ReleaseInfo
    private var currentVersion: String
    private var isHomebrew: Bool

    static func show(release: UpdateChecker.ReleaseInfo, currentVersion: String, isHomebrew: Bool) {
        if let existing = shared {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.runModal(for: existing.window!)
            return
        }
        let controller = UpdateWindow(release: release, currentVersion: currentVersion, isHomebrew: isHomebrew)
        shared = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: controller.window!)
    }

    init(release: UpdateChecker.ReleaseInfo, currentVersion: String, isHomebrew: Bool) {
        self.release = release
        self.currentVersion = currentVersion
        self.isHomebrew = isHomebrew

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 460),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.windowBg
        window.center()

        super.init(window: window)
        window.delegate = self
        window.contentView = buildContent()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Content

    private func buildContent() -> NSView {
        let root = NSView()
        root.wantsLayer = true

        // --- Icon ---
        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        if let icon = AppIcon.image {
            iconView.image = icon
        }
        root.addSubview(iconView)

        // --- Title ---
        let titleLabel = makeLabel("Update Available", size: 18, weight: .bold, color: .white)
        root.addSubview(titleLabel)

        // --- Version comparison ---
        let versionRow = makeVersionRow()
        root.addSubview(versionRow)

        // --- Separator 1 ---
        let sep1 = makeSeparator()
        root.addSubview(sep1)

        // --- Release notes ---
        let notesContainer = makeNotesView()
        root.addSubview(notesContainer)

        // --- Separator 2 ---
        let sep2 = makeSeparator()
        root.addSubview(sep2)

        // --- Button row ---
        let buttonRow = makeButtonRow()
        root.addSubview(buttonRow)

        // --- Layout ---
        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            iconView.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 48),
            iconView.heightAnchor.constraint(equalToConstant: 48),

            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 10),
            titleLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),

            versionRow.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            versionRow.centerXAnchor.constraint(equalTo: root.centerXAnchor),

            sep1.topAnchor.constraint(equalTo: versionRow.bottomAnchor, constant: 14),
            sep1.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            sep1.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            sep1.heightAnchor.constraint(equalToConstant: 1),

            notesContainer.topAnchor.constraint(equalTo: sep1.bottomAnchor, constant: 14),
            notesContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            notesContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),

            sep2.topAnchor.constraint(equalTo: notesContainer.bottomAnchor, constant: 14),
            sep2.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            sep2.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            sep2.heightAnchor.constraint(equalToConstant: 1),

            buttonRow.topAnchor.constraint(equalTo: sep2.bottomAnchor, constant: 14),
            buttonRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            buttonRow.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
        ])

        return root
    }

    // MARK: - Version Row

    private func makeVersionRow() -> NSView {
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY

        let currentLabel = makeLabel("v\(currentVersion)", size: 13, weight: .medium,
                                     color: NSColor(white: 0.45, alpha: 1))

        let arrowLabel = makeLabel("\u{2192}", size: 13, weight: .medium,
                                   color: NSColor(white: 0.45, alpha: 1))

        let newPill = makePill("v\(release.version)", color: Theme.accent)

        stack.addArrangedSubview(currentLabel)
        stack.addArrangedSubview(arrowLabel)
        stack.addArrangedSubview(newPill)
        return stack
    }

    // MARK: - Release Notes

    private func makeNotesView() -> NSView {
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.editorBg
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 6

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        let rendered = renderMarkdown(release.body)
        textView.textStorage?.setAttributedString(rendered)

        scrollView.documentView = textView

        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        // Allow the notes area to fill available space
        let expandConstraint = scrollView.heightAnchor.constraint(equalToConstant: 220)
        expandConstraint.priority = .defaultLow
        expandConstraint.isActive = true

        return scrollView
    }

    // MARK: - Markdown Renderer

    private func renderMarkdown(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = text.components(separatedBy: "\n")

        let bodyFont = NSFont.systemFont(ofSize: 12, weight: .regular)
        let bodyColor = NSColor(white: 0.7, alpha: 1)
        let headingFont = NSFont.systemFont(ofSize: 13, weight: .bold)
        let headingColor = NSColor.white
        let boldFont = NSFont.systemFont(ofSize: 12, weight: .semibold)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 2

        let bulletStyle = NSMutableParagraphStyle()
        bulletStyle.lineSpacing = 2
        bulletStyle.headIndent = 16
        bulletStyle.firstLineHeadIndent = 4

        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                result.append(NSAttributedString(string: "\n", attributes: [
                    .font: bodyFont,
                    .foregroundColor: bodyColor,
                ]))
                continue
            }

            // Heading: ## or #
            if trimmed.hasPrefix("#") {
                let headingText = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                if i > 0 {
                    result.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 6)]))
                }
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: headingFont,
                    .foregroundColor: headingColor,
                    .paragraphStyle: paragraphStyle,
                ]
                result.append(NSAttributedString(string: headingText + "\n", attributes: attrs))
                continue
            }

            // Bullet: - item or * item
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                let bulletText = String(trimmed.dropFirst(2))
                let bulletLine = "\u{2022}  " + bulletText + "\n"
                let attrStr = applyInlineFormatting(bulletLine, baseFont: bodyFont, boldFont: boldFont,
                                                     color: bodyColor, style: bulletStyle)
                result.append(attrStr)
                continue
            }

            // Plain text
            let plainLine = trimmed + "\n"
            let attrStr = applyInlineFormatting(plainLine, baseFont: bodyFont, boldFont: boldFont,
                                                 color: bodyColor, style: paragraphStyle)
            result.append(attrStr)
        }

        return result
    }

    private func applyInlineFormatting(_ text: String, baseFont: NSFont, boldFont: NSFont,
                                        color: NSColor, style: NSParagraphStyle) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: baseFont,
            .foregroundColor: color,
            .paragraphStyle: style,
        ])

        // Apply **bold**
        let pattern = "\\*\\*(.+?)\\*\\*"
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let nsText = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            // Process in reverse to preserve ranges
            for match in matches.reversed() {
                let fullRange = match.range
                let innerRange = match.range(at: 1)
                let innerText = nsText.substring(with: innerRange)
                let boldStr = NSAttributedString(string: innerText, attributes: [
                    .font: boldFont,
                    .foregroundColor: NSColor.white,
                    .paragraphStyle: style,
                ])
                result.replaceCharacters(in: fullRange, with: boldStr)
            }
        }

        return result
    }

    // MARK: - Buttons

    private func makeButtonRow() -> NSView {
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = 10

        let laterBtn = makeButton(title: "Later", isPrimary: false, action: #selector(laterClicked))
        let primaryTitle = isHomebrew ? "Update via Homebrew" : "Download Update"
        let primaryBtn = makeButton(title: primaryTitle, isPrimary: true, action: #selector(primaryClicked))

        stack.addArrangedSubview(laterBtn)
        stack.addArrangedSubview(primaryBtn)
        return stack
    }

    private func makeButton(title: String, isPrimary: Bool, action: Selector) -> NSView {
        let btn = NSButton(title: title, target: self, action: action)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.isBordered = false
        btn.wantsLayer = true
        btn.font = .systemFont(ofSize: 13, weight: isPrimary ? .semibold : .regular)

        if isPrimary {
            btn.contentTintColor = .white
            btn.layer?.backgroundColor = Theme.accent.cgColor
        } else {
            btn.contentTintColor = NSColor(white: 0.70, alpha: 1)
            btn.layer?.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
        }
        btn.layer?.cornerRadius = 6

        // Padding
        btn.heightAnchor.constraint(equalToConstant: 30).isActive = true
        btn.widthAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true

        return btn
    }

    @objc private func laterClicked() {
        window?.close()
    }

    @objc private func primaryClicked() {
        window?.close()
        if isHomebrew {
            UpdateChecker.shared.updateViaHomebrew()
        } else {
            UpdateChecker.shared.openReleasePage()
        }
    }

    // MARK: - Helpers

    private func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.alignment = .center
        label.isSelectable = false
        return label
    }

    private func makePill(_ text: String, color: NSColor) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = color.withAlphaComponent(0.15).cgColor
        container.layer?.cornerRadius = 10

        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        label.textColor = color
        label.isSelectable = false
        container.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -3),
        ])
        return container
    }

    private func makeSeparator() -> NSView {
        let sep = NSView()
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
        return sep
    }
}

// MARK: - NSWindowDelegate

extension UpdateWindow: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        NSApp.stopModal()
        UpdateWindow.shared = nil
    }
}
