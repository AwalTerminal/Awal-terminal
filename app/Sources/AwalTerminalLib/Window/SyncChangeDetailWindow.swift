import AppKit

/// Singleton window showing detailed AI component changes after a sync.
class SyncChangeDetailWindow: NSWindowController {

    private static var shared: SyncChangeDetailWindow?
    private var summary: SyncChangeSummary?

    static func show(summary: SyncChangeSummary) {
        if let existing = shared {
            existing.summary = summary
            existing.rebuildContent()
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.runModal(for: existing.window!)
            return
        }
        let controller = SyncChangeDetailWindow(summary: summary)
        shared = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: controller.window!)
    }

    convenience init(summary: SyncChangeSummary) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "AI Component Updates"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.windowBg
        window.center()

        self.init(window: window)
        self.summary = summary
        window.delegate = self
        rebuildContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override init(window: NSWindow?) {
        super.init(window: window)
    }

    private func rebuildContent() {
        guard let window, let summary else { return }

        // Calculate content height to auto-size the window
        let totalChanges = summary.added.count + summary.modified.count + summary.removed.count
        let typeOrder: [ComponentType] = [.skill, .rule, .prompt, .agent, .mcpServer, .hook]
        var sectionCount = 0
        for type in typeOrder {
            let has = summary.added.contains { $0.type == type }
                || summary.modified.contains { $0.type == type }
                || summary.removed.contains { $0.type == type }
            if has { sectionCount += 1 }
        }
        // 16 top padding + 18 info label + 8 gap + 16 registries label + sections + rows + 16 bottom + 44 close area
        let contentHeight: CGFloat = 16 + 18 + 8 + 16
            + CGFloat(sectionCount) * (16 + 16)  // section gap + section label height
            + CGFloat(totalChanges) * (6 + 24)   // row gap + row height
            + 16 + 44
        let maxHeight: CGFloat = 500
        let windowHeight = min(max(contentHeight, 140), maxHeight)

        let contentView = NSView()
        contentView.wantsLayer = true
        window.contentView = contentView

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scrollView)

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        // Info banner
        let infoLabel = NSTextField(wrappingLabelWithString: "Start new sessions to use the updated components.")
        infoLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        infoLabel.textColor = NSColor(red: 100.0/255.0, green: 180.0/255.0, blue: 255.0/255.0, alpha: 1.0)
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(infoLabel)

        // Registries updated
        let registriesText = "Registries updated: " + summary.registriesUpdated.joined(separator: ", ")
        let registriesLabel = NSTextField(wrappingLabelWithString: registriesText)
        registriesLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        registriesLabel.textColor = NSColor(white: 0.5, alpha: 1.0)
        registriesLabel.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(registriesLabel)

        var lastAnchor = registriesLabel.bottomAnchor

        // Group changes by type
        for type in typeOrder {
            let addedOfType = summary.added.filter { $0.type == type }
            let modifiedOfType = summary.modified.filter { $0.type == type }
            let removedOfType = summary.removed.filter { $0.type == type }
            guard !addedOfType.isEmpty || !modifiedOfType.isEmpty || !removedOfType.isEmpty else { continue }

            let sectionLabel = NSTextField(labelWithString: typeSectionTitle(type))
            sectionLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
            sectionLabel.textColor = NSColor(white: 0.8, alpha: 1.0)
            sectionLabel.translatesAutoresizingMaskIntoConstraints = false
            documentView.addSubview(sectionLabel)

            NSLayoutConstraint.activate([
                sectionLabel.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 16),
                sectionLabel.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -16),
                sectionLabel.topAnchor.constraint(equalTo: lastAnchor, constant: 16),
            ])
            lastAnchor = sectionLabel.bottomAnchor

            for change in addedOfType + modifiedOfType + removedOfType {
                let kind: ChangeKind = addedOfType.contains(where: { $0.name == change.name && $0.stack == change.stack }) ? .added
                    : modifiedOfType.contains(where: { $0.name == change.name && $0.stack == change.stack }) ? .modified
                    : .removed
                let row = makeChangeRow(change: change, kind: kind)
                documentView.addSubview(row)
                NSLayoutConstraint.activate([
                    row.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 24),
                    row.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -16),
                    row.topAnchor.constraint(equalTo: lastAnchor, constant: 6),
                ])
                lastAnchor = row.bottomAnchor
            }
        }

        // Close button
        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeTapped))
        closeButton.bezelStyle = .rounded
        closeButton.focusRingType = .none
        closeButton.refusesFirstResponder = true
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(closeButton)

        NSLayoutConstraint.activate([
            infoLabel.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 16),
            infoLabel.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -16),
            infoLabel.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 16),

            registriesLabel.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 16),
            registriesLabel.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -16),
            registriesLabel.topAnchor.constraint(equalTo: infoLabel.bottomAnchor, constant: 8),

            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            lastAnchor.constraint(lessThanOrEqualTo: documentView.bottomAnchor, constant: -16),

            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: closeButton.topAnchor, constant: -12),

            closeButton.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            closeButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            closeButton.widthAnchor.constraint(equalToConstant: 80),
        ])

        // Resize window to fit content, keeping it centered
        let frame = window.frame
        let newHeight = windowHeight
        let newOrigin = NSPoint(x: frame.origin.x, y: frame.origin.y + frame.height - newHeight)
        window.setFrame(NSRect(x: newOrigin.x, y: newOrigin.y, width: frame.width, height: newHeight), display: true)
    }

    private enum ChangeKind { case added, modified, removed }

    private func makeChangeRow(change: SyncChangeSummary.ComponentChange, kind: ChangeKind) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let prefix: String
        let color: NSColor
        switch kind {
        case .added:
            prefix = "+"
            color = NSColor(red: 120.0/255.0, green: 220.0/255.0, blue: 120.0/255.0, alpha: 1.0)
        case .modified:
            prefix = "~"
            color = NSColor(red: 220.0/255.0, green: 200.0/255.0, blue: 80.0/255.0, alpha: 1.0)
        case .removed:
            prefix = "\u{2212}"
            color = NSColor(red: 220.0/255.0, green: 100.0/255.0, blue: 100.0/255.0, alpha: 1.0)
        }

        let prefixLabel = NSTextField(labelWithString: prefix)
        prefixLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        prefixLabel.textColor = color
        prefixLabel.translatesAutoresizingMaskIntoConstraints = false
        prefixLabel.setContentHuggingPriority(.required, for: .horizontal)
        row.addSubview(prefixLabel)

        let nameLabel = NSTextField(labelWithString: change.name)
        nameLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        nameLabel.textColor = NSColor(white: 0.85, alpha: 1.0)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(nameLabel)

        let detailLabel = NSTextField(labelWithString: "\(change.source) / \(change.stack)")
        detailLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        detailLabel.textColor = NSColor(white: 0.55, alpha: 1.0)
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addSubview(detailLabel)

        NSLayoutConstraint.activate([
            prefixLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            prefixLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            prefixLabel.widthAnchor.constraint(equalToConstant: 16),

            nameLabel.leadingAnchor.constraint(equalTo: prefixLabel.trailingAnchor, constant: 4),
            nameLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            detailLabel.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 8),
            detailLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            detailLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            row.heightAnchor.constraint(equalToConstant: 24),
        ])

        return row
    }

    private func typeSectionTitle(_ type: ComponentType) -> String {
        switch type {
        case .skill: return "Skills"
        case .rule: return "Rules"
        case .prompt: return "Prompts"
        case .agent: return "Agents"
        case .mcpServer: return "MCP Servers"
        case .hook: return "Hooks"
        }
    }

    @objc private func closeTapped() {
        window?.close()
    }
}

extension SyncChangeDetailWindow: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        NSApp.stopModal()
        SyncChangeDetailWindow.shared = nil
    }
}
