import AppKit

/// Dedicated window for managing AI component registries and browsing loaded components.
class AIComponentsManagerWindow: NSWindowController, NSWindowDelegate {

    private static var shared: AIComponentsManagerWindow?

    static func show() {
        if let existing = shared {
            existing.window?.makeKeyAndOrderFront(nil)
            existing.refreshAll()
            NSApp.runModal(for: existing.window!)
            return
        }
        let controller = AIComponentsManagerWindow()
        shared = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: controller.window!)
    }

    /// Show security findings in a standalone window (callable from the menu bar).
    static func showSecurityFindings(_ findings: [SecurityFinding]) {
        guard !findings.isEmpty else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Security Findings — \(findings.count) finding\(findings.count == 1 ? "" : "s")"
        panel.minSize = NSSize(width: 400, height: 250)
        panel.center()

        let contentView = NSView(frame: panel.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]
        panel.contentView = contentView

        // Header
        let header = NSTextField(labelWithString: "All Registries — \(findings.count) finding\(findings.count == 1 ? "" : "s")")
        header.font = .boldSystemFont(ofSize: 13)
        header.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(header)

        // Scroll view with findings list
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 6
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

        for finding in findings {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            row.alignment = .top

            let badge = NSTextField(labelWithString: finding.severity == .critical ? "CRITICAL" : "WARNING")
            badge.font = .boldSystemFont(ofSize: 10)
            badge.textColor = .white
            badge.wantsLayer = true
            badge.layer?.cornerRadius = 3
            badge.layer?.backgroundColor = finding.severity == .critical
                ? NSColor(red: 0.85, green: 0.2, blue: 0.2, alpha: 1).cgColor
                : NSColor(red: 0.8, green: 0.65, blue: 0.2, alpha: 1).cgColor
            badge.alignment = .center
            badge.setContentHuggingPriority(.required, for: .horizontal)
            badge.setContentCompressionResistancePriority(.required, for: .horizontal)

            let detail = NSStackView()
            detail.orientation = .vertical
            detail.alignment = .leading
            detail.spacing = 2

            let componentLabel = NSTextField(labelWithString: finding.componentKey)
            componentLabel.font = .boldSystemFont(ofSize: 11)
            componentLabel.textColor = .secondaryLabelColor

            let desc = NSTextField(labelWithString: finding.pattern)
            desc.font = .systemFont(ofSize: 12)
            desc.lineBreakMode = .byWordWrapping
            desc.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let line = NSTextField(labelWithString: finding.line)
            line.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            line.textColor = .tertiaryLabelColor
            line.lineBreakMode = .byTruncatingTail
            line.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            detail.addArrangedSubview(componentLabel)
            detail.addArrangedSubview(desc)
            detail.addArrangedSubview(line)

            row.addArrangedSubview(badge)
            row.addArrangedSubview(detail)
            stackView.addArrangedSubview(row)
        }

        let clipView = NSClipView()
        clipView.documentView = stackView
        scrollView.contentView = clipView
        contentView.addSubview(scrollView)

        // Dismiss button
        let dismissBtn = NSButton(title: "Done", target: nil, action: nil)
        dismissBtn.translatesAutoresizingMaskIntoConstraints = false
        dismissBtn.bezelStyle = .rounded
        dismissBtn.keyEquivalent = "\u{1b}"
        contentView.addSubview(dismissBtn)

        class PanelDismisser: NSObject {
            weak var panel: NSPanel?
            @objc func dismiss(_ sender: Any) {
                panel?.close()
            }
        }
        let dismisser = PanelDismisser()
        dismisser.panel = panel
        dismissBtn.target = dismisser
        dismissBtn.action = #selector(PanelDismisser.dismiss(_:))
        objc_setAssociatedObject(panel, "dismisser", dismisser, .OBJC_ASSOCIATION_RETAIN)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            header.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            scrollView.bottomAnchor.constraint(equalTo: dismissBtn.topAnchor, constant: -10),

            stackView.widthAnchor.constraint(equalTo: clipView.widthAnchor),

            dismissBtn.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            dismissBtn.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])

        panel.makeKeyAndOrderFront(nil)
    }

    private let registryTableView = NSTableView()
    private let componentTableView = NSTableView()
    private let errorLabel = NSTextField(labelWithString: "")
    private let viewFindingsButton = NSButton(title: "View Findings", target: nil, action: nil)
    private let syncAllButton: NSButton
    private let autoSyncCheck: NSButton
    private let intervalField: NSTextField
    private let segmentedControl = NSSegmentedControl()

    // Components browser data
    private var componentGroups: [ComponentGroup] = []
    /// Segment labels: one per populated component type
    private var tabTypes: [ComponentType] = []
    private var currentTabItems: [(name: String, source: String, stack: String, key: String)] = []

    private struct ComponentGroup {
        let type: ComponentType
        let items: [(name: String, source: String, stack: String, key: String)]
    }

    init() {
        syncAllButton = NSButton(title: "Sync All", target: nil, action: nil)
        autoSyncCheck = NSButton(checkboxWithTitle: "Auto-sync", target: nil, action: nil)
        intervalField = NSTextField(string: "\(AppConfig.shared.aiComponentsSyncInterval / 3600)")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 520),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AI Components"
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 600, height: 400)
        if AppIcon.image != nil { window.representedURL = nil }

        super.init(window: window)
        window.delegate = self

        syncAllButton.target = self
        syncAllButton.action = #selector(syncAllClicked(_:))
        autoSyncCheck.target = self
        autoSyncCheck.action = #selector(autoSyncChanged(_:))
        intervalField.target = self
        intervalField.action = #selector(intervalChanged(_:))

        viewFindingsButton.target = self
        viewFindingsButton.action = #selector(viewFindingsClicked(_:))

        setupUI()
        refreshAll()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(registryStatusChanged(_:)),
            name: RegistryManager.statusDidChange,
            object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.stopModal()
        Self.shared = nil
    }

    // MARK: - UI Setup

    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true

        // -- Top section: Registries (always visible) --
        let regHeader = NSTextField(labelWithString: "Registries")
        regHeader.font = .boldSystemFont(ofSize: 13)
        regHeader.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(regHeader)

        syncAllButton.translatesAutoresizingMaskIntoConstraints = false
        syncAllButton.bezelStyle = .rounded
        contentView.addSubview(syncAllButton)

        let regScroll = NSScrollView()
        regScroll.translatesAutoresizingMaskIntoConstraints = false
        regScroll.hasVerticalScroller = true
        regScroll.borderType = .bezelBorder

        registryTableView.headerView = NSTableHeaderView()
        registryTableView.usesAlternatingRowBackgroundColors = true
        registryTableView.allowsMultipleSelection = false

        let statusCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("status"))
        statusCol.title = ""
        statusCol.width = 24
        statusCol.minWidth = 24
        statusCol.maxWidth = 24
        registryTableView.addTableColumn(statusCol)

        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameCol.title = "Name"
        nameCol.width = 120
        registryTableView.addTableColumn(nameCol)

        let urlCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("url"))
        urlCol.title = "URL"
        urlCol.width = 280
        registryTableView.addTableColumn(urlCol)

        let branchCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("branch"))
        branchCol.title = "Branch"
        branchCol.width = 60
        registryTableView.addTableColumn(branchCol)

        let syncedCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("synced"))
        syncedCol.title = "Last Synced"
        syncedCol.width = 100
        registryTableView.addTableColumn(syncedCol)

        registryTableView.delegate = self
        registryTableView.dataSource = self

        regScroll.documentView = registryTableView
        contentView.addSubview(regScroll)

        let addBtn = NSButton(title: "+ Add", target: self, action: #selector(addRegistryClicked(_:)))
        addBtn.translatesAutoresizingMaskIntoConstraints = false
        addBtn.bezelStyle = .rounded
        contentView.addSubview(addBtn)

        let removeBtn = NSButton(title: "- Remove", target: self, action: #selector(removeRegistryClicked(_:)))
        removeBtn.translatesAutoresizingMaskIntoConstraints = false
        removeBtn.bezelStyle = .rounded
        contentView.addSubview(removeBtn)

        let syncSelectedBtn = NSButton(title: "Sync", target: self, action: #selector(syncSelectedClicked(_:)))
        syncSelectedBtn.translatesAutoresizingMaskIntoConstraints = false
        syncSelectedBtn.bezelStyle = .rounded
        contentView.addSubview(syncSelectedBtn)

        let configureMappingBtn = NSButton(title: "Mapping...", target: self, action: #selector(configureMappingClicked(_:)))
        configureMappingBtn.translatesAutoresizingMaskIntoConstraints = false
        configureMappingBtn.bezelStyle = .rounded
        contentView.addSubview(configureMappingBtn)

        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = NSColor(red: 1, green: 0.4, blue: 0.4, alpha: 1)
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.isEditable = false
        errorLabel.isBordered = false
        errorLabel.drawsBackground = false
        errorLabel.lineBreakMode = .byTruncatingTail
        contentView.addSubview(errorLabel)

        viewFindingsButton.translatesAutoresizingMaskIntoConstraints = false
        viewFindingsButton.bezelStyle = .rounded
        viewFindingsButton.font = .systemFont(ofSize: 11)
        viewFindingsButton.isHidden = true
        contentView.addSubview(viewFindingsButton)

        // -- Divider --
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(divider)

        // -- Components section: segmented tabs + table --
        segmentedControl.segmentStyle = .texturedRounded
        segmentedControl.target = self
        segmentedControl.action = #selector(segmentChanged(_:))
        segmentedControl.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(segmentedControl)

        let compScroll = NSScrollView()
        compScroll.translatesAutoresizingMaskIntoConstraints = false
        compScroll.hasVerticalScroller = true
        compScroll.borderType = .bezelBorder

        let compEnabledCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("comp_enabled"))
        compEnabledCol.title = ""
        compEnabledCol.width = 28
        compEnabledCol.minWidth = 28
        compEnabledCol.maxWidth = 28
        componentTableView.addTableColumn(compEnabledCol)

        let compNameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("comp_name"))
        compNameCol.title = "Name"
        compNameCol.width = 220
        componentTableView.addTableColumn(compNameCol)

        let compRegCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("comp_registry"))
        compRegCol.title = "Registry"
        compRegCol.width = 160
        componentTableView.addTableColumn(compRegCol)

        let compStackCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("comp_stack"))
        compStackCol.title = "Stack"
        compStackCol.width = 120
        componentTableView.addTableColumn(compStackCol)

        componentTableView.headerView = NSTableHeaderView()
        componentTableView.usesAlternatingRowBackgroundColors = true
        componentTableView.delegate = self
        componentTableView.dataSource = self
        componentTableView.doubleAction = #selector(componentDoubleClicked(_:))
        componentTableView.target = self

        compScroll.documentView = componentTableView
        contentView.addSubview(compScroll)

        // -- Bottom bar: sync settings --
        autoSyncCheck.translatesAutoresizingMaskIntoConstraints = false
        autoSyncCheck.state = AppConfig.shared.aiComponentsAutoSync ? .on : .off
        contentView.addSubview(autoSyncCheck)

        let intervalLabel = NSTextField(labelWithString: "Interval:")
        intervalLabel.font = .systemFont(ofSize: 12)
        intervalLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(intervalLabel)

        intervalField.font = .systemFont(ofSize: 12)
        intervalField.translatesAutoresizingMaskIntoConstraints = false
        intervalField.identifier = NSUserInterfaceItemIdentifier("sync_interval")
        contentView.addSubview(intervalField)

        let secLabel = NSTextField(labelWithString: "hours")
        secLabel.font = .systemFont(ofSize: 12)
        secLabel.textColor = .secondaryLabelColor
        secLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(secLabel)

        NSLayoutConstraint.activate([
            // Registry header + sync all
            regHeader.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            regHeader.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            syncAllButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            syncAllButton.centerYAnchor.constraint(equalTo: regHeader.centerYAnchor),

            // Registry table
            regScroll.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            regScroll.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            regScroll.topAnchor.constraint(equalTo: regHeader.bottomAnchor, constant: 8),
            regScroll.heightAnchor.constraint(equalToConstant: 80),

            // Registry buttons
            addBtn.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            addBtn.topAnchor.constraint(equalTo: regScroll.bottomAnchor, constant: 6),
            removeBtn.leadingAnchor.constraint(equalTo: addBtn.trailingAnchor, constant: 6),
            removeBtn.centerYAnchor.constraint(equalTo: addBtn.centerYAnchor),
            syncSelectedBtn.leadingAnchor.constraint(equalTo: removeBtn.trailingAnchor, constant: 6),
            syncSelectedBtn.centerYAnchor.constraint(equalTo: addBtn.centerYAnchor),
            configureMappingBtn.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            configureMappingBtn.centerYAnchor.constraint(equalTo: addBtn.centerYAnchor),

            // Error label + view findings button
            errorLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            errorLabel.trailingAnchor.constraint(equalTo: viewFindingsButton.leadingAnchor, constant: -6),
            errorLabel.topAnchor.constraint(equalTo: addBtn.bottomAnchor, constant: 4),
            viewFindingsButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            viewFindingsButton.centerYAnchor.constraint(equalTo: errorLabel.centerYAnchor),

            // Divider
            divider.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            divider.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            divider.topAnchor.constraint(equalTo: errorLabel.bottomAnchor, constant: 8),

            // Segmented control
            segmentedControl.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 8),
            segmentedControl.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),

            // Component table
            compScroll.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            compScroll.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            compScroll.topAnchor.constraint(equalTo: segmentedControl.bottomAnchor, constant: 8),
            compScroll.bottomAnchor.constraint(equalTo: autoSyncCheck.topAnchor, constant: -10),

            // Bottom bar
            autoSyncCheck.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            autoSyncCheck.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            intervalLabel.leadingAnchor.constraint(equalTo: autoSyncCheck.trailingAnchor, constant: 16),
            intervalLabel.centerYAnchor.constraint(equalTo: autoSyncCheck.centerYAnchor),
            intervalField.leadingAnchor.constraint(equalTo: intervalLabel.trailingAnchor, constant: 6),
            intervalField.centerYAnchor.constraint(equalTo: autoSyncCheck.centerYAnchor),
            intervalField.widthAnchor.constraint(equalToConstant: 60),
            secLabel.leadingAnchor.constraint(equalTo: intervalField.trailingAnchor, constant: 4),
            secLabel.centerYAnchor.constraint(equalTo: autoSyncCheck.centerYAnchor),
        ])
    }

    @objc private func segmentChanged(_ sender: NSSegmentedControl) {
        selectTab(at: sender.selectedSegment)
    }

    private func selectTab(at index: Int) {
        guard index >= 0 && index < tabTypes.count else {
            currentTabItems = []
            componentTableView.reloadData()
            return
        }
        let type = tabTypes[index]
        if let group = componentGroups.first(where: { $0.type == type }) {
            currentTabItems = group.items
        } else {
            currentTabItems = []
        }
        componentTableView.reloadData()
    }

    // MARK: - Data Refresh

    private func refreshAll() {
        // Resolve mapping modes for any registries that haven't been resolved yet
        RegistryManager.shared.resolveMappingsIfNeeded(registries: AppConfig.shared.aiComponentRegistries)
        registryTableView.reloadData()
        refreshComponents()
        updateErrorLabel()
    }

    private func refreshComponents() {
        let config = AppConfig.shared
        let registries = config.aiComponentRegistries

        // Get all detected stacks across all registries
        var allStacks = Set<String>()
        for reg in registries {
            let rules = RegistryManager.shared.parseRegistryToml(name: reg.name)
            for stack in rules.keys {
                allStacks.insert(stack)
            }
        }
        // Also include built-in detection stacks
        for stack in ProjectDetector.builtInRules.keys {
            allStacks.insert(stack)
        }

        let components = AIComponentRegistry.shared.listActiveComponents(
            stacks: allStacks,
            registries: registries
        )

        // Group by type
        let grouped = Dictionary(grouping: components) { $0.type }
        let typeOrder: [ComponentType] = [.skill, .rule, .prompt, .agent, .mcpServer, .hook]
        componentGroups = typeOrder.compactMap { type in
            guard let items = grouped[type], !items.isEmpty else { return nil }
            return ComponentGroup(
                type: type,
                items: items.map { (name: $0.name, source: $0.source, stack: $0.stack, key: $0.key) }
            )
        }

        // Rebuild segmented control
        let previousSelectedType: ComponentType? = {
            let idx = segmentedControl.selectedSegment
            if idx >= 0 && idx < tabTypes.count { return tabTypes[idx] }
            return nil
        }()

        tabTypes = componentGroups.map { $0.type }
        segmentedControl.segmentCount = tabTypes.count
        for (i, type) in tabTypes.enumerated() {
            let count = componentGroups.first(where: { $0.type == type })?.items.count ?? 0
            segmentedControl.setLabel("\(type.pluralLabel.capitalized) (\(count))", forSegment: i)
            segmentedControl.setWidth(0, forSegment: i)
        }

        // Restore selection or default to first
        if let prev = previousSelectedType, let idx = tabTypes.firstIndex(of: prev) {
            segmentedControl.selectedSegment = idx
            selectTab(at: idx)
        } else if !tabTypes.isEmpty {
            segmentedControl.selectedSegment = 0
            selectTab(at: 0)
        } else {
            currentTabItems = []
            componentTableView.reloadData()
        }
    }

    private func updateErrorLabel() {
        let selected = registryTableView.selectedRow
        let registries = AppConfig.shared.aiComponentRegistries

        if selected >= 0 && selected < registries.count {
            let name = registries[selected].name
            if let status = RegistryManager.shared.registryStatuses[name] {
                switch status {
                case .error(let msg):
                    errorLabel.stringValue = "\(name): \(msg)"
                    errorLabel.textColor = NSColor(red: 1, green: 0.4, blue: 0.4, alpha: 1)
                    return
                default:
                    break
                }
            }
            // Show mapping mode info for non-standard registries
            let mode = RegistryManager.shared.mappingModes[name]
            if mode == .unmapped {
                errorLabel.stringValue = "\(name): Non-standard structure. Click 'Configure Mapping' to load components."
                errorLabel.textColor = NSColor(red: 1, green: 0.8, blue: 0.3, alpha: 1)
                return
            }
            if mode == .claudePlugin {
                let count = RegistryManager.shared.mappedComponents[name]?.count ?? 0
                errorLabel.stringValue = "\(name): Auto-detected \(count) skill(s) from .claude-plugin manifest"
                errorLabel.textColor = NSColor(red: 0.5, green: 0.8, blue: 1, alpha: 1)
                return
            }
            if mode == .inRepoMapping || mode == .localMapping {
                let count = RegistryManager.shared.mappedComponents[name]?.count ?? 0
                let label = mode == .localMapping ? "local mapping" : "in-repo .awal-mapping.json"
                errorLabel.stringValue = "\(name): Loaded \(count) component(s) via \(label)"
                errorLabel.textColor = NSColor(red: 0.5, green: 0.8, blue: 1, alpha: 1)
                return
            }

            // Show structure warnings (standard registries only)
            let warnings = RegistryManager.shared.validateStructure(name: name)
            if let first = warnings.first {
                errorLabel.stringValue = "\(name): \(first)"
                errorLabel.textColor = NSColor(red: 1, green: 0.8, blue: 0.3, alpha: 1)
                return
            }

            // Show security findings count
            if let findings = RegistryManager.shared.scanResults[name], !findings.isEmpty {
                let criticalCount = findings.filter { $0.severity == .critical }.count
                let warningCount = findings.filter { $0.severity == .warning }.count
                var parts: [String] = []
                if criticalCount > 0 { parts.append("\(criticalCount) critical") }
                if warningCount > 0 { parts.append("\(warningCount) warning\(warningCount == 1 ? "" : "s")") }
                errorLabel.stringValue = "\(name): \(parts.joined(separator: ", ")) security finding\(findings.count == 1 ? "" : "s")"
                errorLabel.textColor = criticalCount > 0
                    ? NSColor(red: 1, green: 0.4, blue: 0.4, alpha: 1)
                    : NSColor(red: 1, green: 0.8, blue: 0.3, alpha: 1)
                viewFindingsButton.isHidden = false
                return
            }
        }

        errorLabel.stringValue = ""
        viewFindingsButton.isHidden = true
    }

    // MARK: - Actions

    @objc private func syncAllClicked(_ sender: NSButton) {
        let config = AppConfig.shared
        syncAllButton.isEnabled = false
        syncAllButton.title = "Syncing..."

        // Snapshot components in the terminal window so the banner can diff after sync
        let terminalController = NSApp.windows.compactMap { $0.windowController as? TerminalWindowController }.first
        terminalController?.snapshotComponentsForSync()

        RegistryManager.shared.syncAll(registries: config.aiComponentRegistries, force: true) { [weak self] results in
            self?.syncAllButton.isEnabled = true
            self?.syncAllButton.title = "Sync All"
            self?.refreshAll()

            // Check for errors
            let errors = results.compactMap { (name, result) -> String? in
                if case .failure(let err) = result { return "\(name): \(err.localizedDescription)" }
                return nil
            }
            if !errors.isEmpty {
                let alert = NSAlert.branded()
                alert.messageText = "Sync Errors"
                alert.informativeText = errors.joined(separator: "\n")
                alert.alertStyle = .warning
                if let w = self?.window { alert.beginSheetModal(for: w) }
            }
        }
    }

    @objc private func addRegistryClicked(_ sender: NSButton) {
        let alert = NSAlert.branded()
        alert.messageText = "Add AI Component Registry"
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 150))

        // Type selector
        let typeLabel = NSTextField(labelWithString: "Type:")
        typeLabel.frame = NSRect(x: 0, y: 124, width: 55, height: 20)
        container.addSubview(typeLabel)

        let typePopup = NSPopUpButton(frame: NSRect(x: 60, y: 120, width: 295, height: 26))
        typePopup.addItems(withTitles: ["Git Repository", "localskills.sh", "Local Directory"])
        container.addSubview(typePopup)

        // Git fields
        let urlLabel = NSTextField(labelWithString: "URL:")
        urlLabel.frame = NSRect(x: 0, y: 94, width: 55, height: 20)
        container.addSubview(urlLabel)

        let urlField = EditableTextField(frame: NSRect(x: 60, y: 92, width: 295, height: 22))
        urlField.placeholderString = "https://github.com/org/components.git"
        container.addSubview(urlField)

        let nameLabel = NSTextField(labelWithString: "Name:")
        nameLabel.frame = NSRect(x: 0, y: 64, width: 55, height: 20)
        container.addSubview(nameLabel)

        let nameField = EditableTextField(frame: NSRect(x: 60, y: 62, width: 295, height: 22))
        nameField.placeholderString = "auto-filled from URL"
        container.addSubview(nameField)

        let branchLabel = NSTextField(labelWithString: "Branch:")
        branchLabel.frame = NSRect(x: 0, y: 34, width: 55, height: 20)
        container.addSubview(branchLabel)

        let branchField = EditableTextField(frame: NSRect(x: 60, y: 32, width: 295, height: 22))
        branchField.stringValue = "main"
        container.addSubview(branchField)

        let tagLabel = NSTextField(labelWithString: "Tag:")
        tagLabel.frame = NSRect(x: 0, y: 4, width: 55, height: 20)
        container.addSubview(tagLabel)

        let tagField = EditableTextField(frame: NSRect(x: 60, y: 2, width: 295, height: 22))
        tagField.placeholderString = "optional (e.g. v1.0.0)"
        container.addSubview(tagField)

        // localskills fields (hidden initially)
        let slugsLabel = NSTextField(labelWithString: "Slugs:")
        slugsLabel.frame = NSRect(x: 0, y: 94, width: 55, height: 20)
        slugsLabel.isHidden = true
        container.addSubview(slugsLabel)

        let slugsField = EditableTextField(frame: NSRect(x: 60, y: 92, width: 295, height: 22))
        slugsField.placeholderString = "skill-slug-1, skill-slug-2"
        slugsField.isHidden = true
        container.addSubview(slugsField)

        // Local directory fields (hidden initially)
        let pathLabel = NSTextField(labelWithString: "Path:")
        pathLabel.frame = NSRect(x: 0, y: 94, width: 55, height: 20)
        pathLabel.isHidden = true
        container.addSubview(pathLabel)

        let pathField = EditableTextField(frame: NSRect(x: 60, y: 92, width: 220, height: 22))
        pathField.placeholderString = "/path/to/components"
        pathField.isHidden = true
        container.addSubview(pathField)

        let browseBtn = NSButton(title: "Browse...", target: nil, action: nil)
        browseBtn.frame = NSRect(x: 285, y: 90, width: 70, height: 24)
        browseBtn.bezelStyle = .rounded
        browseBtn.isHidden = true
        container.addSubview(browseBtn)

        // Git-specific fields list
        let gitFields: [NSView] = [urlLabel, urlField, branchLabel, branchField, tagLabel, tagField]
        let localskillsFields: [NSView] = [slugsLabel, slugsField]
        let localFields: [NSView] = [pathLabel, pathField, browseBtn]

        // Type change handler
        class TypeChangeTarget: NSObject {
            let gitFields: [NSView]
            let localskillsFields: [NSView]
            let localFields: [NSView]
            let nameField: NSTextField
            let typePopup: NSPopUpButton

            init(gitFields: [NSView], localskillsFields: [NSView], localFields: [NSView], nameField: NSTextField, typePopup: NSPopUpButton) {
                self.gitFields = gitFields
                self.localskillsFields = localskillsFields
                self.localFields = localFields
                self.nameField = nameField
                self.typePopup = typePopup
            }

            @objc func typeChanged(_ sender: NSPopUpButton) {
                let idx = sender.indexOfSelectedItem
                for v in gitFields { v.isHidden = idx != 0 }
                for v in localskillsFields { v.isHidden = idx != 1 }
                for v in localFields { v.isHidden = idx != 2 }
                nameField.placeholderString = idx == 0 ? "auto-filled from URL" : "registry name"
            }
        }

        let typeTarget = TypeChangeTarget(
            gitFields: gitFields, localskillsFields: localskillsFields,
            localFields: localFields, nameField: nameField, typePopup: typePopup
        )
        typePopup.target = typeTarget
        typePopup.action = #selector(TypeChangeTarget.typeChanged(_:))

        // Browse button handler
        class BrowseTarget: NSObject {
            let pathField: NSTextField
            init(pathField: NSTextField) { self.pathField = pathField }
            @objc func browse(_ sender: NSButton) {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.canCreateDirectories = true
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url {
                    pathField.stringValue = url.path
                }
            }
        }

        let browseTarget = BrowseTarget(pathField: pathField)
        browseBtn.target = browseTarget
        browseBtn.action = #selector(BrowseTarget.browse(_:))

        alert.accessoryView = container
        alert.window.initialFirstResponder = urlField

        guard let w = window else { return }
        alert.beginSheetModal(for: w) { [weak self] response in
            // Keep targets alive through closure
            _ = typeTarget
            _ = browseTarget

            guard response == .alertFirstButtonReturn else { return }
            let selectedType = typePopup.indexOfSelectedItem

            var name = nameField.stringValue.trimmingCharacters(in: .whitespaces)

            switch selectedType {
            case 0: // Git
                let url = urlField.stringValue.trimmingCharacters(in: .whitespaces)
                let branch = branchField.stringValue.trimmingCharacters(in: .whitespaces)

                guard !url.isEmpty else {
                    let errAlert = NSAlert.branded()
                    errAlert.messageText = "Missing URL"
                    errAlert.informativeText = "A repository URL is required."
                    errAlert.alertStyle = .warning
                    if let w = self?.window { errAlert.beginSheetModal(for: w) }
                    return
                }

                if name.isEmpty {
                    name = url.components(separatedBy: "/").last?
                        .replacingOccurrences(of: ".git", with: "") ?? "registry"
                }

                let effectiveBranch = branch.isEmpty ? "main" : branch
                let tag = tagField.stringValue.trimmingCharacters(in: .whitespaces)
                ConfigWriter.updateValue(key: "ai_components.registry.\(name).url", value: "\"\(url)\"")
                ConfigWriter.updateValue(key: "ai_components.registry.\(name).branch", value: "\"\(effectiveBranch)\"")
                if !tag.isEmpty {
                    ConfigWriter.updateValue(key: "ai_components.registry.\(name).tag", value: "\"\(tag)\"")
                }
                AppConfig.reload()
                self?.refreshAll()

                let regConfig = RegistryConfig(name: name, url: url, branch: effectiveBranch, tag: tag.isEmpty ? nil : tag)
                DispatchQueue.global(qos: .utility).async {
                    let result = RegistryManager.shared.syncOne(registry: regConfig)
                    DispatchQueue.main.async {
                        self?.refreshAll()
                        if case .failure(let err) = result {
                            let errAlert = NSAlert.branded()
                            errAlert.messageText = "Clone Failed"
                            errAlert.informativeText = err.localizedDescription
                            errAlert.alertStyle = .warning
                            if let w = self?.window { errAlert.beginSheetModal(for: w) }
                        }
                    }
                }

            case 1: // localskills
                let slugsStr = slugsField.stringValue.trimmingCharacters(in: .whitespaces)
                guard !slugsStr.isEmpty else {
                    let errAlert = NSAlert.branded()
                    errAlert.messageText = "Missing Slugs"
                    errAlert.informativeText = "At least one skill slug is required."
                    errAlert.alertStyle = .warning
                    if let w = self?.window { errAlert.beginSheetModal(for: w) }
                    return
                }
                if name.isEmpty { name = "localskills" }

                let slugs = slugsStr.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                ConfigWriter.updateValue(key: "ai_components.registry.\(name).type", value: "\"localskills\"")
                ConfigWriter.updateValue(key: "ai_components.registry.\(name).slugs", value: "\"\(slugs.joined(separator: ","))\"")
                AppConfig.reload()
                self?.refreshAll()

                let regConfig = RegistryConfig(name: name, url: "", branch: "main", type: .localskills, slugs: slugs)
                DispatchQueue.global(qos: .utility).async {
                    let result = RegistryManager.shared.syncOne(registry: regConfig)
                    DispatchQueue.main.async {
                        self?.refreshAll()
                        if case .failure(let err) = result {
                            let errAlert = NSAlert.branded()
                            errAlert.messageText = "Sync Failed"
                            errAlert.informativeText = err.localizedDescription
                            errAlert.alertStyle = .warning
                            if let w = self?.window { errAlert.beginSheetModal(for: w) }
                        }
                    }
                }

            case 2: // Local directory
                let path = pathField.stringValue.trimmingCharacters(in: .whitespaces)
                guard !path.isEmpty else {
                    let errAlert = NSAlert.branded()
                    errAlert.messageText = "Missing Path"
                    errAlert.informativeText = "A directory path is required."
                    errAlert.alertStyle = .warning
                    if let w = self?.window { errAlert.beginSheetModal(for: w) }
                    return
                }
                if name.isEmpty {
                    name = URL(fileURLWithPath: path).lastPathComponent
                }

                ConfigWriter.updateValue(key: "ai_components.registry.\(name).type", value: "\"local\"")
                ConfigWriter.updateValue(key: "ai_components.registry.\(name).path", value: "\"\(path)\"")
                AppConfig.reload()
                self?.refreshAll()

                let regConfig = RegistryConfig(name: name, url: "", branch: "main", type: .local, path: path)
                DispatchQueue.global(qos: .utility).async {
                    let result = RegistryManager.shared.syncOne(registry: regConfig)
                    DispatchQueue.main.async {
                        self?.refreshAll()
                        if case .failure(let err) = result {
                            let errAlert = NSAlert.branded()
                            errAlert.messageText = "Sync Failed"
                            errAlert.informativeText = err.localizedDescription
                            errAlert.alertStyle = .warning
                            if let w = self?.window { errAlert.beginSheetModal(for: w) }
                        }
                    }
                }

            default:
                break
            }
        }
    }

    @objc private func configureMappingClicked(_ sender: NSButton) {
        let idx = registryTableView.selectedRow
        let registries = AppConfig.shared.aiComponentRegistries
        guard idx >= 0 && idx < registries.count else {
            let alert = NSAlert.branded()
            alert.messageText = "No Registry Selected"
            alert.informativeText = "Select a registry first, then click Configure Mapping."
            alert.alertStyle = .informational
            if let w = window { alert.beginSheetModal(for: w) }
            return
        }
        let reg = registries[idx]
        MappingEditorWindow.show(registryName: reg.name)
    }

    @objc private func removeRegistryClicked(_ sender: NSButton) {
        let idx = registryTableView.selectedRow
        let registries = AppConfig.shared.aiComponentRegistries
        guard idx >= 0 && idx < registries.count else { return }

        let reg = registries[idx]
        // Remove all possible config keys for any registry type
        for key in ["url", "branch", "tag", "type", "slugs", "path", "mapping"] {
            ConfigWriter.removeValue(key: "ai_components.registry.\(reg.name).\(key)")
        }
        AppConfig.reload()
        RegistryManager.shared.removeRegistry(name: reg.name)
        refreshAll()
    }

    @objc private func syncSelectedClicked(_ sender: NSButton) {
        let idx = registryTableView.selectedRow
        let registries = AppConfig.shared.aiComponentRegistries
        guard idx >= 0 && idx < registries.count else { return }

        let reg = registries[idx]
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = RegistryManager.shared.syncOne(registry: reg)
            DispatchQueue.main.async {
                self?.refreshAll()
                if case .failure(let err) = result {
                    let alert = NSAlert.branded()
                    alert.messageText = "Sync Failed"
                    alert.informativeText = err.localizedDescription
                    alert.alertStyle = .warning
                    if let w = self?.window { alert.beginSheetModal(for: w) }
                }
            }
        }
    }

    @objc private func autoSyncChanged(_ sender: NSButton) {
        ConfigWriter.updateValue(key: "ai_components.auto_sync", value: sender.state == .on ? "true" : "false")
    }

    @objc private func intervalChanged(_ sender: NSTextField) {
        let value = sender.stringValue.trimmingCharacters(in: .whitespaces)
        if let hours = Int(value) {
            ConfigWriter.updateValue(key: "ai_components.sync_interval", value: "\(hours * 3600)")
        }
    }

    @objc private func registryStatusChanged(_ notification: Notification) {
        registryTableView.reloadData()
        updateErrorLabel()
    }

    // MARK: - Helpers

    private func formatRelativeTime(_ date: Date) -> String {
        let elapsed = Int(Date().timeIntervalSince(date))
        if elapsed < 60 { return "\(elapsed)s ago" }
        if elapsed < 3600 { return "\(elapsed / 60)m ago" }
        return "\(elapsed / 3600)h ago"
    }
}

// MARK: - NSTableView DataSource & Delegate

extension AIComponentsManagerWindow: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === registryTableView {
            return AppConfig.shared.aiComponentRegistries.count
        }
        if tableView === componentTableView {
            return currentTabItems.count
        }
        return 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === registryTableView {
            return registryView(for: tableColumn, row: row)
        }
        if tableView === componentTableView {
            return componentView(for: tableColumn, row: row)
        }
        return nil
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        22
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        guard tableView === componentTableView, row < currentTabItems.count else { return nil }
        let item = currentTabItems[row]

        let allFindings = RegistryManager.shared.scanResults.values.flatMap { $0 }
        let componentFindings = allFindings.filter { $0.componentKey == item.key }
        guard !componentFindings.isEmpty else { return nil }

        let rowView = NSTableRowView()
        rowView.wantsLayer = true
        let hasCritical = componentFindings.contains { $0.severity == .critical }
        rowView.layer?.backgroundColor = hasCritical
            ? NSColor(red: 1, green: 0.2, blue: 0.2, alpha: 0.1).cgColor
            : NSColor(red: 1, green: 0.85, blue: 0.2, alpha: 0.1).cgColor
        return rowView
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if (notification.object as? NSTableView) === registryTableView {
            updateErrorLabel()
        }
    }

    // MARK: Registry table cells

    private func registryView(for tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let registries = AppConfig.shared.aiComponentRegistries
        guard row < registries.count else { return nil }
        let reg = registries[row]

        switch tableColumn?.identifier.rawValue {
        case "status":
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 12)
            label.alignment = .center

            let status = RegistryManager.shared.registryStatuses[reg.name]
            let mappingMode = RegistryManager.shared.mappingModes[reg.name]
            switch status {
            case .synced:
                label.stringValue = "\u{25CF}"
                if mappingMode == .unmapped {
                    // Non-standard, no mapping configured — orange
                    label.textColor = NSColor(red: 1, green: 0.7, blue: 0.2, alpha: 1)
                } else if mappingMode != nil && mappingMode != .standard {
                    // Mapped registry — blue
                    label.textColor = NSColor(red: 0.4, green: 0.7, blue: 1, alpha: 1)
                } else {
                    let warnings = RegistryManager.shared.validateStructure(name: reg.name)
                    label.textColor = warnings.isEmpty
                        ? NSColor(red: 0.3, green: 0.8, blue: 0.4, alpha: 1)
                        : NSColor(red: 1, green: 0.3, blue: 0.3, alpha: 1)
                }
            case .syncing:
                label.stringValue = "\u{25CF}"
                label.textColor = NSColor(red: 0.4, green: 0.6, blue: 1, alpha: 1)
            case .error:
                label.stringValue = "\u{25CF}"
                label.textColor = NSColor(red: 1, green: 0.3, blue: 0.3, alpha: 1)
            case .notCloned, .none:
                if RegistryManager.shared.isCloned(name: reg.name) {
                    let warnings = RegistryManager.shared.validateStructure(name: reg.name)
                    label.stringValue = "\u{25CF}"
                    label.textColor = warnings.isEmpty
                        ? NSColor(red: 0.3, green: 0.8, blue: 0.4, alpha: 1)
                        : NSColor(red: 1, green: 0.3, blue: 0.3, alpha: 1)
                } else {
                    label.stringValue = "\u{25CB}"
                    label.textColor = NSColor(white: 0.5, alpha: 1)
                }
            }
            return label

        case "name":
            let cell = NSTextField(labelWithString: reg.name)
            cell.font = .systemFont(ofSize: 12)
            cell.lineBreakMode = .byTruncatingTail
            return cell

        case "url":
            let displayText: String
            switch reg.type {
            case .git:
                displayText = reg.url
                    .replacingOccurrences(of: "https://github.com/", with: "github.com/")
                    .replacingOccurrences(of: ".git", with: "")
            case .localskills:
                displayText = "localskills: \(reg.slugs.joined(separator: ", "))"
            case .local:
                displayText = reg.path ?? ""
            }
            let cell = NSTextField(labelWithString: displayText)
            cell.font = .systemFont(ofSize: 12)
            cell.textColor = .secondaryLabelColor
            cell.lineBreakMode = .byTruncatingTail
            return cell

        case "branch":
            let displayValue: String
            switch reg.type {
            case .git:
                displayValue = reg.tag.map { "tag:\($0)" } ?? reg.branch
            case .localskills, .local:
                displayValue = "\u{2014}"
            }
            let cell = NSTextField(labelWithString: displayValue)
            cell.font = .systemFont(ofSize: 12)
            cell.textColor = .secondaryLabelColor
            return cell

        case "synced":
            let cell = NSTextField(labelWithString: "")
            cell.font = .systemFont(ofSize: 11)
            cell.textColor = .secondaryLabelColor
            if let date = RegistryManager.shared.lastSyncTime(name: reg.name) {
                cell.stringValue = formatRelativeTime(date)
            } else {
                cell.stringValue = "\u{2014}"
            }
            return cell

        default:
            return nil
        }
    }

    // MARK: Component table cells

    private func componentView(for tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < currentTabItems.count else { return nil }
        let item = currentTabItems[row]

        switch tableColumn?.identifier.rawValue {
        case "comp_enabled":
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(componentToggled(_:)))
            checkbox.tag = row
            // For hooks with approval enabled, checkbox reflects approval status
            let isHookTab = {
                let idx = self.segmentedControl.selectedSegment
                return idx >= 0 && idx < self.tabTypes.count && self.tabTypes[idx] == .hook
            }()
            if isHookTab, AppConfig.shared.aiComponentsRequireHookApproval {
                if let url = resolveHookURL(key: item.key) {
                    checkbox.state = HookApprovalStore.shared.isApproved(key: item.key, fileURL: url) ? .on : .off
                } else {
                    checkbox.state = .off
                }
            } else {
                let isDisabled = AppConfig.shared.aiComponentsDisabled.contains(item.key)
                checkbox.state = isDisabled ? .off : .on
            }
            return checkbox

        case "comp_name":
            let cell = NSTextField(labelWithString: "")
            cell.font = .systemFont(ofSize: 12)
            cell.lineBreakMode = .byTruncatingTail
            // Show security indicator
            let hasFindings = RegistryManager.shared.scanResults.values
                .flatMap { $0 }
                .contains { $0.componentKey == item.key }
            // Show hook approval indicator
            let isHookTab = {
                let idx = segmentedControl.selectedSegment
                return idx >= 0 && idx < tabTypes.count && tabTypes[idx] == .hook
            }()
            if isHookTab, AppConfig.shared.aiComponentsRequireHookApproval {
                if let url = resolveHookURL(key: item.key) {
                    let approved = HookApprovalStore.shared.isApproved(key: item.key, fileURL: url)
                    let dot = approved ? "\u{1F7E2} " : "\u{1F7E0} "
                    cell.stringValue = dot + item.name
                } else {
                    cell.stringValue = "\u{1F7E0} " + item.name
                }
            } else if hasFindings {
                let hasCritical = RegistryManager.shared.scanResults.values
                    .flatMap { $0 }
                    .contains { $0.componentKey == item.key && $0.severity == .critical }
                if let shieldImage = NSImage(systemSymbolName: "shield.trianglebadge.exclamationmark", accessibilityDescription: "Security finding") {
                    let attachment = NSTextAttachment()
                    attachment.image = shieldImage
                    let attrStr = NSMutableAttributedString(attachment: attachment)
                    attrStr.append(NSAttributedString(string: " " + item.name))
                    cell.attributedStringValue = attrStr
                    cell.textColor = hasCritical
                        ? NSColor(red: 1, green: 0.4, blue: 0.4, alpha: 1)
                        : NSColor(red: 1, green: 0.8, blue: 0.3, alpha: 1)
                } else {
                    let dot = hasCritical ? "\u{1F534} " : "\u{1F7E1} "
                    cell.stringValue = dot + item.name
                }
            } else {
                cell.stringValue = item.name
            }
            return cell

        case "comp_registry":
            let cell = NSTextField(labelWithString: item.source)
            cell.font = .systemFont(ofSize: 12)
            cell.textColor = .secondaryLabelColor
            cell.lineBreakMode = .byTruncatingTail
            return cell

        case "comp_stack":
            let cell = NSTextField(labelWithString: item.stack)
            cell.font = .systemFont(ofSize: 12)
            cell.textColor = .secondaryLabelColor
            cell.lineBreakMode = .byTruncatingTail
            return cell

        default:
            return nil
        }
    }

    @objc private func componentToggled(_ sender: NSButton) {
        let row = sender.tag
        guard row < currentTabItems.count else { return }
        let item = currentTabItems[row]

        // Hook approval flow: toggling ON an unapproved hook shows a confirmation alert
        let isHookTab = {
            let idx = self.segmentedControl.selectedSegment
            return idx >= 0 && idx < self.tabTypes.count && self.tabTypes[idx] == .hook
        }()

        if isHookTab, AppConfig.shared.aiComponentsRequireHookApproval {
            if sender.state == .on {
                // Approve: show the script contents for review
                if let url = resolveHookURL(key: item.key),
                   let contents = try? String(contentsOf: url, encoding: .utf8) {
                    let alert = NSAlert()
                    alert.messageText = "Approve hook script?"
                    alert.informativeText = "Review the script before approving:\n\n\(contents.prefix(2000))"
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Approve")
                    alert.addButton(withTitle: "Cancel")
                    let response = alert.runModal()
                    if response == .alertFirstButtonReturn {
                        HookApprovalStore.shared.approve(key: item.key, fileURL: url)
                    } else {
                        sender.state = .off
                    }
                } else {
                    sender.state = .off
                }
            } else {
                // Revoke approval
                HookApprovalStore.shared.revoke(key: item.key)
            }
            componentTableView.reloadData()
            return
        }

        var disabled = AppConfig.shared.aiComponentsDisabled
        if sender.state == .off {
            disabled.insert(item.key)
        } else {
            disabled.remove(item.key)
        }

        let value = disabled.sorted().joined(separator: ",")
        ConfigWriter.updateValue(key: "ai_components.disabled", value: "\"\(value)\"")
        AppConfig.reload()
    }

    @objc private func componentDoubleClicked(_ sender: Any) {
        let row = componentTableView.clickedRow
        guard row >= 0 && row < currentTabItems.count else { return }
        let item = currentTabItems[row]

        let findings = RegistryManager.shared.scanResults.values
            .flatMap { $0 }
            .filter { $0.componentKey == item.key }
        guard !findings.isEmpty else { return }
        showSecurityDetailSheet(findings: findings, title: item.key)
    }

    @objc private func viewFindingsClicked(_ sender: NSButton) {
        let selected = registryTableView.selectedRow
        let registries = AppConfig.shared.aiComponentRegistries
        guard selected >= 0 && selected < registries.count else { return }
        let name = registries[selected].name
        guard let findings = RegistryManager.shared.scanResults[name], !findings.isEmpty else { return }
        showSecurityDetailSheet(findings: findings, title: name)
    }

    private func showSecurityDetailSheet(findings: [SecurityFinding], title: String) {
        guard let parentWindow = window else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Security Findings"
        panel.minSize = NSSize(width: 400, height: 250)

        let contentView = NSView(frame: panel.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]
        panel.contentView = contentView

        // Header
        let header = NSTextField(labelWithString: "\(title) \u{2014} \(findings.count) finding\(findings.count == 1 ? "" : "s")")
        header.font = .boldSystemFont(ofSize: 13)
        header.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(header)

        // Scroll view with findings list
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 6
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

        for finding in findings {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            row.alignment = .top

            // Severity badge
            let badge = NSTextField(labelWithString: finding.severity == .critical ? "CRITICAL" : "WARNING")
            badge.font = .boldSystemFont(ofSize: 10)
            badge.textColor = .white
            badge.wantsLayer = true
            badge.layer?.cornerRadius = 3
            badge.layer?.backgroundColor = finding.severity == .critical
                ? NSColor(red: 0.85, green: 0.2, blue: 0.2, alpha: 1).cgColor
                : NSColor(red: 0.8, green: 0.65, blue: 0.2, alpha: 1).cgColor
            badge.alignment = .center
            badge.setContentHuggingPriority(.required, for: .horizontal)
            badge.setContentCompressionResistancePriority(.required, for: .horizontal)

            // Description + matched line
            let detail = NSStackView()
            detail.orientation = .vertical
            detail.alignment = .leading
            detail.spacing = 2

            let desc = NSTextField(labelWithString: finding.pattern)
            desc.font = .systemFont(ofSize: 12)
            desc.lineBreakMode = .byWordWrapping
            desc.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let line = NSTextField(labelWithString: finding.line)
            line.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            line.textColor = .secondaryLabelColor
            line.lineBreakMode = .byTruncatingTail
            line.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            detail.addArrangedSubview(desc)
            detail.addArrangedSubview(line)

            row.addArrangedSubview(badge)
            row.addArrangedSubview(detail)
            stackView.addArrangedSubview(row)
        }

        let clipView = NSClipView()
        clipView.documentView = stackView
        scrollView.contentView = clipView
        contentView.addSubview(scrollView)

        // Dismiss button
        let dismissBtn = NSButton(title: "Done", target: nil, action: nil)
        dismissBtn.translatesAutoresizingMaskIntoConstraints = false
        dismissBtn.bezelStyle = .rounded
        dismissBtn.keyEquivalent = "\u{1b}"
        contentView.addSubview(dismissBtn)

        class SheetDismisser: NSObject {
            weak var parentWindow: NSWindow?
            weak var panel: NSPanel?
            @objc func dismiss(_ sender: Any) {
                guard let parent = parentWindow, let sheet = panel else { return }
                parent.endSheet(sheet)
            }
        }
        let dismisser = SheetDismisser()
        dismisser.parentWindow = parentWindow
        dismisser.panel = panel
        dismissBtn.target = dismisser
        dismissBtn.action = #selector(SheetDismisser.dismiss(_:))
        objc_setAssociatedObject(panel, "dismisser", dismisser, .OBJC_ASSOCIATION_RETAIN)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            header.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            scrollView.bottomAnchor.constraint(equalTo: dismissBtn.topAnchor, constant: -10),

            stackView.widthAnchor.constraint(equalTo: clipView.widthAnchor),

            dismissBtn.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            dismissBtn.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])

        parentWindow.beginSheet(panel)
    }

    /// Resolve a hook component key to its file URL on disk.
    /// Key format: `registryName/stack/hook/subdir/scriptName`
    private func resolveHookURL(key: String) -> URL? {
        let parts = key.split(separator: "/", maxSplits: 3)
        guard parts.count == 4 else { return nil }
        let registryName = String(parts[0])
        let stack = String(parts[1])
        // parts[2] == "hook"
        let hookPath = String(parts[3]) // e.g. "pre-session/myscript"

        // For mapped registries, look up the URL from resolved components
        let mode = RegistryManager.shared.mappingModes[registryName]
        if mode != nil && mode != .standard {
            if let resolved = RegistryManager.shared.mappedComponents[registryName] {
                for comp in resolved where comp.type == .hook {
                    let compKey = "\(registryName)/\(comp.stack)/hook/\(comp.name)"
                    if compKey == key { return comp.fileURL }
                }
            }
        }

        let regPath = RegistryManager.shared.registryPath(name: registryName)
        let stackPrefix = stack == "common" ? "common" : "stacks/\(stack)"
        let baseDir = regPath.appendingPathComponent("\(stackPrefix)/hooks")

        // Try common script extensions
        for ext in ["sh", "bash", "zsh", "py", "rb"] {
            let candidate = baseDir.appendingPathComponent("\(hookPath).\(ext)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        // Try without extension
        let noExt = baseDir.appendingPathComponent(hookPath)
        if FileManager.default.fileExists(atPath: noExt.path) {
            return noExt
        }
        return nil
    }
}

// MARK: - NSTextField subclass that supports Cmd+V/C/X/A inside NSAlert

private class EditableTextField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), let chars = event.charactersIgnoringModifiers {
            let action: Selector? = switch chars {
            case "v": #selector(NSText.paste(_:))
            case "c": #selector(NSText.copy(_:))
            case "x": #selector(NSText.cut(_:))
            case "a": #selector(NSText.selectAll(_:))
            default: nil
            }
            if let action, NSApp.sendAction(action, to: nil, from: self) {
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}
