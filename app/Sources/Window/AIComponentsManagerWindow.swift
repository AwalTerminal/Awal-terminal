import AppKit

/// Dedicated window for managing AI component registries and browsing loaded components.
class AIComponentsManagerWindow: NSWindowController, NSWindowDelegate {

    private static var shared: AIComponentsManagerWindow?

    static func show() {
        if let existing = shared {
            existing.window?.makeKeyAndOrderFront(nil)
            existing.refreshAll()
            return
        }
        let controller = AIComponentsManagerWindow()
        shared = controller
        controller.showWindow(nil)
    }

    private let registryTableView = NSTableView()
    private let componentTableView = NSTableView()
    private let errorLabel = NSTextField(labelWithString: "")
    private let syncAllButton: NSButton
    private let autoSyncCheck: NSButton
    private let intervalField: NSTextField
    private let segmentedControl = NSSegmentedControl()

    // Components browser data
    private var componentGroups: [ComponentGroup] = []
    /// Segment labels: one per populated component type
    private var tabTypes: [ComponentType] = []
    private var currentTabItems: [(name: String, source: String, stack: String)] = []

    private struct ComponentGroup {
        let type: ComponentType
        let items: [(name: String, source: String, stack: String)]
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

        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = NSColor(red: 1, green: 0.4, blue: 0.4, alpha: 1)
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.isEditable = false
        errorLabel.isBordered = false
        errorLabel.drawsBackground = false
        errorLabel.lineBreakMode = .byTruncatingTail
        contentView.addSubview(errorLabel)

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

        let compNameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("comp_name"))
        compNameCol.title = "Name"
        compNameCol.width = 240
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

            // Error label
            errorLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            errorLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            errorLabel.topAnchor.constraint(equalTo: addBtn.bottomAnchor, constant: 4),

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
                items: items.map { (name: $0.name, source: $0.source, stack: $0.stack) }
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
            // Show structure warnings
            let warnings = RegistryManager.shared.validateStructure(name: name)
            if let first = warnings.first {
                errorLabel.stringValue = "\(name): \(first)"
                errorLabel.textColor = NSColor(red: 1, green: 0.8, blue: 0.3, alpha: 1)
                return
            }
        }

        errorLabel.stringValue = ""
    }

    // MARK: - Actions

    @objc private func syncAllClicked(_ sender: NSButton) {
        let config = AppConfig.shared
        syncAllButton.isEnabled = false
        syncAllButton.title = "Syncing..."

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

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 90))

        let urlLabel = NSTextField(labelWithString: "URL:")
        urlLabel.frame = NSRect(x: 0, y: 64, width: 55, height: 20)
        container.addSubview(urlLabel)

        let urlField = EditableTextField(frame: NSRect(x: 60, y: 62, width: 295, height: 22))
        urlField.placeholderString = "https://github.com/org/components.git"
        container.addSubview(urlField)

        let nameLabel = NSTextField(labelWithString: "Name:")
        nameLabel.frame = NSRect(x: 0, y: 34, width: 55, height: 20)
        container.addSubview(nameLabel)

        let nameField = EditableTextField(frame: NSRect(x: 60, y: 32, width: 295, height: 22))
        nameField.placeholderString = "auto-filled from URL"
        container.addSubview(nameField)

        let branchLabel = NSTextField(labelWithString: "Branch:")
        branchLabel.frame = NSRect(x: 0, y: 4, width: 55, height: 20)
        container.addSubview(branchLabel)

        let branchField = EditableTextField(frame: NSRect(x: 60, y: 2, width: 295, height: 22))
        branchField.stringValue = "main"
        container.addSubview(branchField)

        alert.accessoryView = container
        alert.window.initialFirstResponder = urlField

        guard let w = window else { return }
        alert.beginSheetModal(for: w) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
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

            // Auto-derive name from URL if not provided
            var name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
            if name.isEmpty {
                name = url.components(separatedBy: "/").last?
                    .replacingOccurrences(of: ".git", with: "") ?? "registry"
            }

            let effectiveBranch = branch.isEmpty ? "main" : branch
            ConfigWriter.updateValue(key: "ai_components.registry.\(name).url", value: "\"\(url)\"")
            ConfigWriter.updateValue(key: "ai_components.registry.\(name).branch", value: "\"\(effectiveBranch)\"")
            AppConfig.reload()
            self?.refreshAll()

            // Trigger initial clone
            DispatchQueue.global(qos: .utility).async {
                let result = RegistryManager.shared.syncOne(name: name, url: url, branch: effectiveBranch)
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
        }
    }

    @objc private func removeRegistryClicked(_ sender: NSButton) {
        let idx = registryTableView.selectedRow
        let registries = AppConfig.shared.aiComponentRegistries
        guard idx >= 0 && idx < registries.count else { return }

        let reg = registries[idx]
        ConfigWriter.removeValue(key: "ai_components.registry.\(reg.name).url")
        ConfigWriter.removeValue(key: "ai_components.registry.\(reg.name).branch")
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
            let result = RegistryManager.shared.syncOne(name: reg.name, url: reg.url, branch: reg.branch)
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
            switch status {
            case .synced:
                let warnings = RegistryManager.shared.validateStructure(name: reg.name)
                label.stringValue = "\u{25CF}"
                label.textColor = warnings.isEmpty
                    ? NSColor(red: 0.3, green: 0.8, blue: 0.4, alpha: 1)
                    : NSColor(red: 1, green: 0.3, blue: 0.3, alpha: 1)
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
            let shortened = reg.url
                .replacingOccurrences(of: "https://github.com/", with: "github.com/")
                .replacingOccurrences(of: ".git", with: "")
            let cell = NSTextField(labelWithString: shortened)
            cell.font = .systemFont(ofSize: 12)
            cell.textColor = .secondaryLabelColor
            cell.lineBreakMode = .byTruncatingTail
            return cell

        case "branch":
            let cell = NSTextField(labelWithString: reg.branch)
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

        let cell = NSTextField(labelWithString: "")
        cell.font = .systemFont(ofSize: 12)
        cell.lineBreakMode = .byTruncatingTail

        switch tableColumn?.identifier.rawValue {
        case "comp_name":
            cell.stringValue = item.name
        case "comp_registry":
            cell.stringValue = item.source
            cell.textColor = .secondaryLabelColor
        case "comp_stack":
            cell.stringValue = item.stack
            cell.textColor = .secondaryLabelColor
        default:
            break
        }
        return cell
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
