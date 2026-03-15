import AppKit

class AboutWindow: NSWindowController {

    private static var shared: AboutWindow?

    static func show() {
        if let existing = shared {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.runModal(for: existing.window!)
            return
        }
        let controller = AboutWindow()
        shared = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: controller.window!)
    }

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = Theme.windowBg
        window.center()

        self.init(window: window)
        window.delegate = self
        window.contentView = buildContent()
    }

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

        // --- App name ---
        let nameLabel = makeLabel("Awal Terminal", size: 22, weight: .bold, color: .white)
        root.addSubview(nameLabel)

        // --- Tagline ---
        let tagline = makeLabel("LLM-native terminal emulator", size: 12, weight: .regular,
                                color: NSColor(white: 0.5, alpha: 1))
        root.addSubview(tagline)

        // --- Version pill ---
        let versionText = Self.appVersion()
        let versionPill = makePill(versionText, color: Theme.accent)
        root.addSubview(versionPill)

        // --- Separator ---
        let sep1 = makeSeparator()
        root.addSubview(sep1)

        // --- Info grid ---
        let gridStack = NSStackView()
        gridStack.translatesAutoresizingMaskIntoConstraints = false
        gridStack.orientation = .vertical
        gridStack.alignment = .leading
        gridStack.spacing = 6

        let commitHash = Self.gitCommitShort()

        let rows: [(String, String)] = [
            ("macOS", Self.platformString()),
            ("Config", "~/.config/awal/config.toml"),
            ("Build", commitHash ?? "dev"),
        ]

        for (key, value) in rows {
            let row = makeInfoRow(key: key, value: value)
            gridStack.addArrangedSubview(row)
        }

        root.addSubview(gridStack)

        // --- Separator ---
        let sep2 = makeSeparator()
        root.addSubview(sep2)

        // --- Keyboard shortcuts hint ---
        let shortcutsStack = NSStackView()
        shortcutsStack.translatesAutoresizingMaskIntoConstraints = false
        shortcutsStack.orientation = .vertical
        shortcutsStack.alignment = .centerX
        shortcutsStack.spacing = 3

        let shortcuts: [(String, String)] = [
            ("\u{2318}T", "New Tab"),
            ("\u{2318}D", "Split Right"),
            ("\u{21E7}\u{2318}I", "AI Side Panel"),
            ("\u{2318},", "Settings"),
        ]
        let shortcutRow = NSStackView()
        shortcutRow.translatesAutoresizingMaskIntoConstraints = false
        shortcutRow.orientation = .horizontal
        shortcutRow.spacing = 12
        for (key, action) in shortcuts {
            let chip = makeShortcutChip(key: key, action: action)
            shortcutRow.addArrangedSubview(chip)
        }
        shortcutsStack.addArrangedSubview(shortcutRow)
        root.addSubview(shortcutsStack)

        // --- Copyright ---
        let copyrightLabel = makeLabel("\u{00A9} 2026 Awal Terminal", size: 11, weight: .regular,
                                       color: NSColor(white: 0.3, alpha: 1))
        root.addSubview(copyrightLabel)

        // --- Layout ---
        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: root.topAnchor, constant: 36),
            iconView.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 80),
            iconView.heightAnchor.constraint(equalToConstant: 80),

            nameLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 12),
            nameLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),

            tagline.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),
            tagline.centerXAnchor.constraint(equalTo: root.centerXAnchor),

            versionPill.topAnchor.constraint(equalTo: tagline.bottomAnchor, constant: 10),
            versionPill.centerXAnchor.constraint(equalTo: root.centerXAnchor),

            sep1.topAnchor.constraint(equalTo: versionPill.bottomAnchor, constant: 16),
            sep1.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            sep1.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
            sep1.heightAnchor.constraint(equalToConstant: 1),

            gridStack.topAnchor.constraint(equalTo: sep1.bottomAnchor, constant: 16),
            gridStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 36),
            gridStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -36),

            sep2.topAnchor.constraint(equalTo: gridStack.bottomAnchor, constant: 16),
            sep2.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            sep2.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
            sep2.heightAnchor.constraint(equalToConstant: 1),

            shortcutsStack.topAnchor.constraint(equalTo: sep2.bottomAnchor, constant: 14),
            shortcutsStack.centerXAnchor.constraint(equalTo: root.centerXAnchor),

            copyrightLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            copyrightLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
        ])

        return root
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

    private func makeInfoRow(key: String, value: String) -> NSView {
        let row = NSStackView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.spacing = 8

        let keyLabel = NSTextField(labelWithString: key)
        keyLabel.font = .systemFont(ofSize: 11, weight: .medium)
        keyLabel.textColor = NSColor(white: 0.45, alpha: 1)
        keyLabel.isSelectable = false
        keyLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        keyLabel.widthAnchor.constraint(equalToConstant: 50).isActive = true
        keyLabel.alignment = .right

        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        valueLabel.textColor = NSColor(white: 0.75, alpha: 1)
        valueLabel.isSelectable = true
        valueLabel.lineBreakMode = .byTruncatingTail

        row.addArrangedSubview(keyLabel)
        row.addArrangedSubview(valueLabel)
        return row
    }

    private func makeShortcutChip(key: String, action: String) -> NSView {
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 2

        let keyContainer = NSView()
        keyContainer.translatesAutoresizingMaskIntoConstraints = false
        keyContainer.wantsLayer = true
        keyContainer.layer?.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
        keyContainer.layer?.cornerRadius = 4
        keyContainer.layer?.borderWidth = 0.5
        keyContainer.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor

        let keyLabel = NSTextField(labelWithString: key)
        keyLabel.translatesAutoresizingMaskIntoConstraints = false
        keyLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        keyLabel.textColor = NSColor(white: 0.7, alpha: 1)
        keyLabel.isSelectable = false
        keyContainer.addSubview(keyLabel)

        NSLayoutConstraint.activate([
            keyLabel.leadingAnchor.constraint(equalTo: keyContainer.leadingAnchor, constant: 6),
            keyLabel.trailingAnchor.constraint(equalTo: keyContainer.trailingAnchor, constant: -6),
            keyLabel.topAnchor.constraint(equalTo: keyContainer.topAnchor, constant: 2),
            keyLabel.bottomAnchor.constraint(equalTo: keyContainer.bottomAnchor, constant: -2),
        ])

        let actionLabel = NSTextField(labelWithString: action)
        actionLabel.font = .systemFont(ofSize: 9, weight: .regular)
        actionLabel.textColor = NSColor(white: 0.4, alpha: 1)
        actionLabel.isSelectable = false

        stack.addArrangedSubview(keyContainer)
        stack.addArrangedSubview(actionLabel)
        return stack
    }

    // MARK: - System Info

    private static func appVersion() -> String {
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, !v.isEmpty {
            return "v\(v)"
        }
        // Fallback: read latest git tag (useful during debug builds)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["describe", "--tags", "--abbrev=0"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let tag = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty {
                return tag
            }
        } catch {}
        return "dev"
    }

    private static func platformString() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let arch: String
        #if arch(arm64)
        arch = "Apple Silicon"
        #else
        arch = "Intel"
        #endif
        return "macOS \(version.majorVersion).\(version.minorVersion) (\(arch))"
    }

    private static func gitCommitShort() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["rev-parse", "--short", "HEAD"]
        // Try to find the repo root relative to executable
        let execURL = URL(fileURLWithPath: CommandLine.arguments[0])
        var dir = execURL.deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) {
                proc.currentDirectoryURL = dir
                break
            }
            dir = dir.deletingLastPathComponent()
        }
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}

// MARK: - NSWindowDelegate

extension AboutWindow: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        NSApp.stopModal()
        AboutWindow.shared = nil
    }
}
