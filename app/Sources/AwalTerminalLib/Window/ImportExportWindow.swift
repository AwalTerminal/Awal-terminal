import AppKit

/// Unified window for importing and exporting AI components.
class ImportExportWindow: NSWindowController, NSWindowDelegate {

    private static var shared: ImportExportWindow?

    static func show() {
        if let existing = shared {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.runModal(for: existing.window!)
            return
        }
        let controller = ImportExportWindow()
        shared = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: controller.window!)
    }

    // MARK: - Shared state

    private let tabControl: NSSegmentedControl = {
        let ctrl = NSSegmentedControl(labels: ["Import", "Export"], trackingMode: .selectOne, target: nil, action: nil)
        ctrl.segmentStyle = .capsule
        return ctrl
    }()
    private let importContainer = NSView()
    private let exportContainer = NSView()

    // Import controls
    private let importCursorCheck = NSButton(checkboxWithTitle: "Cursor Rules — Import .cursor/rules/*.mdc files", target: nil, action: nil)
    private let importAgentsCheck = NSButton(checkboxWithTitle: "AGENTS.md — Import sections from AGENTS.md", target: nil, action: nil)
    private let importCodexCheck = NSButton(checkboxWithTitle: "Codex Skills — Import from .codex/skills/ directories", target: nil, action: nil)
    private let selectFolderButton = NSButton(title: "Select Project Folder...", target: nil, action: nil)
    private let selectedPathLabel = NSTextField(labelWithString: "No folder selected")
    private let importButton = NSButton(title: "Import", target: nil, action: nil)
    private let importResultsView = NSTextView()
    private var selectedProjectURL: URL?

    // Export controls
    private let exportCursorCheck = NSButton(checkboxWithTitle: "Cursor — Write .cursor/rules/<name>.mdc files", target: nil, action: nil)
    private let exportAgentsCheck = NSButton(checkboxWithTitle: "AGENTS.md — Write a single AGENTS.md file", target: nil, action: nil)
    private let exportCopilotCheck = NSButton(checkboxWithTitle: "GitHub Copilot — Write .github/copilot-instructions.md", target: nil, action: nil)
    private let exportContinueCheck = NSButton(checkboxWithTitle: "Continue.dev — Write .continue/rules/<name>.md files", target: nil, action: nil)
    private let targetCacheRadio = NSButton(radioButtonWithTitle: "Cache (~/.config/awal/exports/)", target: nil, action: nil)
    private let targetProjectRadio = NSButton(radioButtonWithTitle: "Project directory", target: nil, action: nil)
    private let exportButton = NSButton(title: "Export", target: nil, action: nil)
    private let exportResultsView = NSTextView()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Import & Export Components"
        window.center()
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.windowBg

        super.init(window: window)
        window.delegate = self

        tabControl.target = self
        tabControl.action = #selector(tabChanged(_:))
        selectFolderButton.target = self
        selectFolderButton.action = #selector(selectFolder(_:))
        importButton.target = self
        importButton.action = #selector(runImport(_:))
        exportButton.target = self
        exportButton.action = #selector(runExport(_:))
        targetCacheRadio.target = self
        targetCacheRadio.action = #selector(targetChanged(_:))
        targetProjectRadio.target = self
        targetProjectRadio.action = #selector(targetChanged(_:))

        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        NSApp.stopModal()
        Self.shared = nil
    }

    // MARK: - UI Setup

    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true

        // Tab control
        tabControl.translatesAutoresizingMaskIntoConstraints = false
        tabControl.selectedSegment = 0
        contentView.addSubview(tabControl)

        // Containers
        importContainer.translatesAutoresizingMaskIntoConstraints = false
        exportContainer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(importContainer)
        contentView.addSubview(exportContainer)

        NSLayoutConstraint.activate([
            tabControl.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            tabControl.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),

            importContainer.topAnchor.constraint(equalTo: tabControl.bottomAnchor, constant: 12),
            importContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            importContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            importContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            exportContainer.topAnchor.constraint(equalTo: tabControl.bottomAnchor, constant: 12),
            exportContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            exportContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            exportContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        setupImportTab()
        setupExportTab()

        exportContainer.isHidden = true
    }

    private func setupImportTab() {
        let header = NSTextField(labelWithString: "Import rules and skills from other AI coding tools into Awal's component format.")
        header.font = .systemFont(ofSize: 12)
        header.textColor = .secondaryLabelColor
        header.lineBreakMode = .byWordWrapping
        header.preferredMaxLayoutWidth = 460
        header.translatesAutoresizingMaskIntoConstraints = false
        importContainer.addSubview(header)

        for check in [importCursorCheck, importAgentsCheck, importCodexCheck] {
            check.translatesAutoresizingMaskIntoConstraints = false
            check.state = .on
            importContainer.addSubview(check)
        }

        selectFolderButton.translatesAutoresizingMaskIntoConstraints = false
        selectFolderButton.bezelStyle = .rounded
        importContainer.addSubview(selectFolderButton)

        selectedPathLabel.translatesAutoresizingMaskIntoConstraints = false
        selectedPathLabel.font = .systemFont(ofSize: 11)
        selectedPathLabel.textColor = .secondaryLabelColor
        selectedPathLabel.lineBreakMode = .byTruncatingMiddle
        importContainer.addSubview(selectedPathLabel)

        importButton.translatesAutoresizingMaskIntoConstraints = false
        importButton.bezelStyle = .rounded
        importButton.isEnabled = false
        importButton.contentTintColor = .white
        importButton.wantsLayer = true
        importButton.layer?.backgroundColor = Theme.accent.cgColor
        importButton.layer?.cornerRadius = 6
        importContainer.addSubview(importButton)

        let resultsScroll = NSScrollView()
        resultsScroll.translatesAutoresizingMaskIntoConstraints = false
        resultsScroll.hasVerticalScroller = true
        resultsScroll.borderType = .noBorder
        resultsScroll.drawsBackground = true
        resultsScroll.backgroundColor = Theme.editorBg
        resultsScroll.wantsLayer = true
        resultsScroll.layer?.cornerRadius = 6
        importResultsView.isEditable = false
        importResultsView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        importResultsView.textContainerInset = NSSize(width: 8, height: 8)
        importResultsView.isVerticallyResizable = true
        importResultsView.autoresizingMask = [.width]
        resultsScroll.documentView = importResultsView
        importContainer.addSubview(resultsScroll)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: importContainer.topAnchor, constant: 4),
            header.leadingAnchor.constraint(equalTo: importContainer.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: importContainer.trailingAnchor, constant: -20),

            importCursorCheck.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            importCursorCheck.leadingAnchor.constraint(equalTo: importContainer.leadingAnchor, constant: 20),

            importAgentsCheck.topAnchor.constraint(equalTo: importCursorCheck.bottomAnchor, constant: 10),
            importAgentsCheck.leadingAnchor.constraint(equalTo: importCursorCheck.leadingAnchor),

            importCodexCheck.topAnchor.constraint(equalTo: importAgentsCheck.bottomAnchor, constant: 10),
            importCodexCheck.leadingAnchor.constraint(equalTo: importCursorCheck.leadingAnchor),

            selectFolderButton.topAnchor.constraint(equalTo: importCodexCheck.bottomAnchor, constant: 12),
            selectFolderButton.leadingAnchor.constraint(equalTo: importContainer.leadingAnchor, constant: 20),

            selectedPathLabel.centerYAnchor.constraint(equalTo: selectFolderButton.centerYAnchor),
            selectedPathLabel.leadingAnchor.constraint(equalTo: selectFolderButton.trailingAnchor, constant: 8),
            selectedPathLabel.trailingAnchor.constraint(equalTo: importContainer.trailingAnchor, constant: -20),

            importButton.topAnchor.constraint(equalTo: selectFolderButton.bottomAnchor, constant: 12),
            importButton.leadingAnchor.constraint(equalTo: importContainer.leadingAnchor, constant: 20),

            resultsScroll.topAnchor.constraint(equalTo: importButton.bottomAnchor, constant: 10),
            resultsScroll.leadingAnchor.constraint(equalTo: importContainer.leadingAnchor, constant: 20),
            resultsScroll.trailingAnchor.constraint(equalTo: importContainer.trailingAnchor, constant: -20),
            resultsScroll.bottomAnchor.constraint(equalTo: importContainer.bottomAnchor, constant: -16),
        ])
    }

    private func setupExportTab() {
        let header = NSTextField(labelWithString: "Export Awal's assembled components to formats used by other AI coding tools.")
        header.font = .systemFont(ofSize: 12)
        header.textColor = .secondaryLabelColor
        header.lineBreakMode = .byWordWrapping
        header.preferredMaxLayoutWidth = 460
        header.translatesAutoresizingMaskIntoConstraints = false
        exportContainer.addSubview(header)

        for check in [exportCursorCheck, exportAgentsCheck, exportCopilotCheck, exportContinueCheck] {
            check.translatesAutoresizingMaskIntoConstraints = false
            check.state = .on
            exportContainer.addSubview(check)
        }

        let targetLabel = NSTextField(labelWithString: "Target:")
        targetLabel.font = .boldSystemFont(ofSize: 12)
        targetLabel.translatesAutoresizingMaskIntoConstraints = false
        exportContainer.addSubview(targetLabel)

        targetCacheRadio.translatesAutoresizingMaskIntoConstraints = false
        targetCacheRadio.state = .on
        exportContainer.addSubview(targetCacheRadio)

        targetProjectRadio.translatesAutoresizingMaskIntoConstraints = false
        targetProjectRadio.state = .off
        exportContainer.addSubview(targetProjectRadio)

        exportButton.translatesAutoresizingMaskIntoConstraints = false
        exportButton.bezelStyle = .rounded
        exportButton.contentTintColor = .white
        exportButton.wantsLayer = true
        exportButton.layer?.backgroundColor = Theme.accent.cgColor
        exportButton.layer?.cornerRadius = 6
        exportContainer.addSubview(exportButton)

        let resultsScroll = NSScrollView()
        resultsScroll.translatesAutoresizingMaskIntoConstraints = false
        resultsScroll.hasVerticalScroller = true
        resultsScroll.borderType = .noBorder
        resultsScroll.drawsBackground = true
        resultsScroll.backgroundColor = Theme.editorBg
        resultsScroll.wantsLayer = true
        resultsScroll.layer?.cornerRadius = 6
        exportResultsView.isEditable = false
        exportResultsView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        exportResultsView.textContainerInset = NSSize(width: 8, height: 8)
        exportResultsView.isVerticallyResizable = true
        exportResultsView.autoresizingMask = [.width]
        resultsScroll.documentView = exportResultsView
        exportContainer.addSubview(resultsScroll)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: exportContainer.topAnchor, constant: 4),
            header.leadingAnchor.constraint(equalTo: exportContainer.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: exportContainer.trailingAnchor, constant: -20),

            exportCursorCheck.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            exportCursorCheck.leadingAnchor.constraint(equalTo: exportContainer.leadingAnchor, constant: 20),

            exportAgentsCheck.topAnchor.constraint(equalTo: exportCursorCheck.bottomAnchor, constant: 10),
            exportAgentsCheck.leadingAnchor.constraint(equalTo: exportCursorCheck.leadingAnchor),

            exportCopilotCheck.topAnchor.constraint(equalTo: exportAgentsCheck.bottomAnchor, constant: 10),
            exportCopilotCheck.leadingAnchor.constraint(equalTo: exportCursorCheck.leadingAnchor),

            exportContinueCheck.topAnchor.constraint(equalTo: exportCopilotCheck.bottomAnchor, constant: 10),
            exportContinueCheck.leadingAnchor.constraint(equalTo: exportCursorCheck.leadingAnchor),

            targetLabel.topAnchor.constraint(equalTo: exportContinueCheck.bottomAnchor, constant: 12),
            targetLabel.leadingAnchor.constraint(equalTo: exportContainer.leadingAnchor, constant: 20),

            targetCacheRadio.centerYAnchor.constraint(equalTo: targetLabel.centerYAnchor),
            targetCacheRadio.leadingAnchor.constraint(equalTo: targetLabel.trailingAnchor, constant: 8),

            targetProjectRadio.centerYAnchor.constraint(equalTo: targetLabel.centerYAnchor),
            targetProjectRadio.leadingAnchor.constraint(equalTo: targetCacheRadio.trailingAnchor, constant: 12),

            exportButton.topAnchor.constraint(equalTo: targetLabel.bottomAnchor, constant: 12),
            exportButton.leadingAnchor.constraint(equalTo: exportContainer.leadingAnchor, constant: 20),

            resultsScroll.topAnchor.constraint(equalTo: exportButton.bottomAnchor, constant: 10),
            resultsScroll.leadingAnchor.constraint(equalTo: exportContainer.leadingAnchor, constant: 20),
            resultsScroll.trailingAnchor.constraint(equalTo: exportContainer.trailingAnchor, constant: -20),
            resultsScroll.bottomAnchor.constraint(equalTo: exportContainer.bottomAnchor, constant: -16),
        ])
    }

    // MARK: - Actions

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        let isImport = sender.selectedSegment == 0
        importContainer.isHidden = !isImport
        exportContainer.isHidden = isImport
    }

    @objc private func selectFolder(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select project directory to import components from"
        panel.prompt = "Select"

        guard let w = window else { return }
        panel.beginSheetModal(for: w) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.selectedProjectURL = url
            self?.selectedPathLabel.stringValue = url.path
            self?.importButton.isEnabled = true
        }
    }

    @objc private func runImport(_ sender: NSButton) {
        guard let projectDir = selectedProjectURL else { return }

        let registryDir = RegistryManager.shared.localRegistryPath
        try? FileManager.default.createDirectory(
            at: registryDir.appendingPathComponent("common/rules"),
            withIntermediateDirectories: true
        )
        try? FileManager.default.createDirectory(
            at: registryDir.appendingPathComponent("common/skills"),
            withIntermediateDirectories: true
        )

        var lines: [String] = []

        if importCursorCheck.state == .on {
            let result = ComponentImporter.importCursorRules(from: projectDir, to: registryDir)
            lines.append("Cursor Rules: \(result.importedCount) imported")
            for w in result.warnings { lines.append("  \u{26A0} \(w)") }
        }

        if importAgentsCheck.state == .on {
            let result = ComponentImporter.importAgentsMd(from: projectDir, to: registryDir)
            lines.append("AGENTS.md: \(result.importedCount) imported")
            for w in result.warnings { lines.append("  \u{26A0} \(w)") }
        }

        if importCodexCheck.state == .on {
            let result = ComponentImporter.importCodexSkills(from: projectDir, to: registryDir)
            lines.append("Codex Skills: \(result.importedCount) imported")
            for w in result.warnings { lines.append("  \u{26A0} \(w)") }
        }

        importResultsView.string = lines.joined(separator: "\n")
    }

    @objc private func targetChanged(_ sender: NSButton) {
        if sender === targetCacheRadio {
            targetCacheRadio.state = .on
            targetProjectRadio.state = .off
        } else {
            targetCacheRadio.state = .off
            targetProjectRadio.state = .on
        }
    }

    @objc private func runExport(_ sender: NSButton) {
        let config = AppConfig.shared
        let registries = config.aiComponentRegistries

        // Get stacks from the most recent terminal window (not keyWindow — that's us)
        var stacks = Set<String>()
        for window in NSApp.orderedWindows {
            if let controller = window.windowController as? TerminalWindowController {
                let focused = controller.tabs[controller.activeTabIndex].splitContainer.focusedTerminal
                if let ctx = focused.lastAIComponentContext {
                    stacks = ctx.detectedStacks
                }
                break
            }
        }

        guard !stacks.isEmpty else {
            exportResultsView.string = "No stacks detected. Start an AI session first to detect project stacks."
            return
        }

        var formats: [ExportFormat] = []
        if exportCursorCheck.state == .on { formats.append(.cursor) }
        if exportAgentsCheck.state == .on { formats.append(.agentsMd) }
        if exportCopilotCheck.state == .on { formats.append(.copilot) }
        if exportContinueCheck.state == .on { formats.append(.continuedev) }

        guard !formats.isEmpty else {
            exportResultsView.string = "No export formats selected."
            return
        }

        let target: ExportTarget = targetCacheRadio.state == .on ? .cache : .project
        let projectPath = FileManager.default.currentDirectoryPath

        let results = ComponentExporter.export(
            stacks: stacks,
            registries: registries,
            formats: formats,
            target: target,
            projectPath: projectPath,
            disabledComponents: config.aiComponentsDisabled
        )

        if results.isEmpty {
            exportResultsView.string = "No components found to export."
        } else {
            var lines: [String] = []
            for r in results {
                lines.append("\(r.format.rawValue): \(r.fileCount) file\(r.fileCount == 1 ? "" : "s")")
                lines.append("  \u{2192} \(r.outputPath.path)")
            }
            exportResultsView.string = lines.joined(separator: "\n")
        }
    }
}
