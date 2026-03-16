import AppKit

// MARK: - File Tree Model

class FileTreeNode {
    let name: String
    let relativePath: String
    var children: [FileTreeNode]
    var isDirectory: Bool
    var matchedType: ComponentType?
    var matchedMappingIndex: Int?

    init(name: String, relativePath: String, isDirectory: Bool, children: [FileTreeNode] = []) {
        self.name = name
        self.relativePath = relativePath
        self.isDirectory = isDirectory
        self.children = children
    }

    static func buildTree(from paths: [String]) -> [FileTreeNode] {
        let root = FileTreeNode(name: "", relativePath: "", isDirectory: true)

        for path in paths {
            let parts = path.split(separator: "/").map(String.init)
            var current = root

            for (i, part) in parts.enumerated() {
                let isLast = (i == parts.count - 1)
                let partialPath = parts[0...i].joined(separator: "/")

                if let existing = current.children.first(where: { $0.name == part && $0.relativePath == partialPath }) {
                    if !isLast { existing.isDirectory = true }
                    current = existing
                } else {
                    // Determine if directory: not last, OR last but another path extends it
                    let isDir = !isLast
                    let node = FileTreeNode(name: part, relativePath: partialPath, isDirectory: isDir)
                    current.children.append(node)
                    if isDir {
                        current = node
                    }
                }
            }
        }

        sortTree(root)
        return root.children
    }

    private static func sortTree(_ node: FileTreeNode) {
        node.children.sort { a, b in
            if a.isDirectory != b.isDirectory {
                return a.isDirectory  // dirs first
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        for child in node.children where child.isDirectory {
            sortTree(child)
        }
    }

    func clearMatches() {
        matchedType = nil
        matchedMappingIndex = nil
        for child in children { child.clearMatches() }
    }

    /// Propagate match highlights from children up to parent directories.
    @discardableResult
    func propagateMatches() -> Bool {
        if isDirectory {
            var hasMatch = matchedType != nil
            for child in children {
                if child.propagateMatches() {
                    if matchedType == nil { matchedType = child.matchedType }
                    hasMatch = true
                }
            }
            return hasMatch
        }
        return matchedType != nil
    }
}

// MARK: - Type Colors

private let typeColors: [ComponentType: NSColor] = [
    .skill: NSColor.systemBlue,
    .rule: NSColor.systemGreen,
    .prompt: NSColor.systemOrange,
    .agent: NSColor.systemPurple,
    .hook: NSColor.systemRed,
    .mcpServer: NSColor.systemTeal,
]

// MARK: - Mapping Editor Window

/// Visual editor for creating/editing registry mapping files.
/// Allows users to map non-standard repo structures to Awal component types.
class MappingEditorWindow: NSWindowController, NSWindowDelegate {

    private static var shared: MappingEditorWindow?

    private let registryName: String
    private let repoPath: URL

    private let fileOutlineView = NSOutlineView()
    private let mappingTableView = NSTableView()
    private let previewTableView = NSTableView()
    private let previewSummaryLabel = NSTextField(labelWithString: "")
    private var mappingRows: [MappingRow] = []
    private var fileTreeNodes: [FileTreeNode] = []
    private var resolvedDetailed: [(mappingIndex: Int, component: ResolvedComponent)] = []
    private var selectedMappingIndex: Int? // For per-row highlighting

    private struct MappingRow {
        var path: String
        var type: String
        var stack: String
    }

    static func show(registryName: String) {
        if let existing = shared {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.runModal(for: existing.window!)
            return
        }

        let repoPath = RegistryManager.shared.registryPath(name: registryName)
        let controller = MappingEditorWindow(registryName: registryName, repoPath: repoPath)
        shared = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: controller.window!)
    }

    init(registryName: String, repoPath: URL) {
        self.registryName = registryName
        self.repoPath = repoPath

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Mapping Editor — \(registryName)"
        window.center()
        window.minSize = NSSize(width: 720, height: 480)

        super.init(window: window)
        window.delegate = self

        loadExistingMapping()
        let rawPaths = RegistryMappingResolver.repoFileTree(repoPath: repoPath, maxDepth: 5)
        fileTreeNodes = FileTreeNode.buildTree(from: rawPaths)
        setupUI()
        updateMatchHighlights()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        NSApp.stopModal()
        MappingEditorWindow.shared = nil
    }

    // MARK: - Setup

    private func loadExistingMapping() {
        if let mapping = RegistryMappingResolver.loadMapping(registryName: registryName, repoPath: repoPath) {
            mappingRows = mapping.mappings.map { entry in
                MappingRow(path: entry.path, type: entry.type, stack: entry.stack ?? "common")
            }
        }
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true

        // Title + glob help button
        let titleLabel = NSTextField(labelWithString: "Configure component mapping for '\(registryName)'")
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleLabel)

        let helpBtn = NSButton(title: "?", target: self, action: #selector(showGlobHelp(_:)))
        helpBtn.bezelStyle = .circular
        helpBtn.font = .systemFont(ofSize: 11, weight: .bold)
        helpBtn.translatesAutoresizingMaskIntoConstraints = false
        helpBtn.toolTip = "Glob pattern reference"
        contentView.addSubview(helpBtn)

        // Left: hierarchical file tree
        let treeLabel = NSTextField(labelWithString: "Repository Files")
        treeLabel.font = .systemFont(ofSize: 11, weight: .medium)
        treeLabel.textColor = .secondaryLabelColor
        treeLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(treeLabel)

        let treeScrollView = NSScrollView()
        treeScrollView.hasVerticalScroller = true
        treeScrollView.hasHorizontalScroller = true
        treeScrollView.autohidesScrollers = true
        treeScrollView.translatesAutoresizingMaskIntoConstraints = false
        treeScrollView.borderType = .bezelBorder

        let treeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("FileNode"))
        treeCol.isEditable = false
        treeCol.minWidth = 50
        treeCol.resizingMask = [.autoresizingMask]
        fileOutlineView.addTableColumn(treeCol)
        fileOutlineView.outlineTableColumn = treeCol
        fileOutlineView.headerView = nil
        fileOutlineView.rowHeight = 20
        fileOutlineView.indentationPerLevel = 16
        fileOutlineView.dataSource = self
        fileOutlineView.delegate = self
        fileOutlineView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        fileOutlineView.autoresizesOutlineColumn = true
        fileOutlineView.intercellSpacing = NSSize(width: 0, height: 0)
        fileOutlineView.focusRingType = .none

        // Context menu
        let contextMenu = NSMenu()
        contextMenu.delegate = self
        fileOutlineView.menu = contextMenu

        treeScrollView.documentView = fileOutlineView
        contentView.addSubview(treeScrollView)

        // Right: mapping rows
        let mappingLabel = NSTextField(labelWithString: "Mappings")
        mappingLabel.font = .systemFont(ofSize: 11, weight: .medium)
        mappingLabel.textColor = .secondaryLabelColor
        mappingLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(mappingLabel)

        let mappingScroll = NSScrollView()
        mappingScroll.hasVerticalScroller = true
        mappingScroll.translatesAutoresizingMaskIntoConstraints = false
        mappingScroll.borderType = .bezelBorder

        let pathCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("map_path"))
        pathCol.title = "Path Glob"
        pathCol.width = 200
        mappingTableView.addTableColumn(pathCol)

        let typeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("map_type"))
        typeCol.title = "Type"
        typeCol.width = 90
        mappingTableView.addTableColumn(typeCol)

        let stackCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("map_stack"))
        stackCol.title = "Stack"
        stackCol.width = 80
        mappingTableView.addTableColumn(stackCol)

        mappingTableView.rowHeight = 24
        mappingTableView.dataSource = self
        mappingTableView.delegate = self
        mappingTableView.tag = 2
        mappingScroll.documentView = mappingTableView
        contentView.addSubview(mappingScroll)

        // Buttons
        let addBtn = NSButton(title: "Add Mapping", target: self, action: #selector(addMappingClicked))
        addBtn.bezelStyle = .rounded
        addBtn.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(addBtn)

        let removeBtn = NSButton(title: "Remove", target: self, action: #selector(removeMappingClicked))
        removeBtn.bezelStyle = .rounded
        removeBtn.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(removeBtn)

        let saveBtn = NSButton(title: "Save", target: self, action: #selector(saveClicked))
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        saveBtn.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(saveBtn)

        // Preview section
        let previewTitle = NSTextField(labelWithString: "Preview")
        previewTitle.font = .systemFont(ofSize: 11, weight: .medium)
        previewTitle.textColor = .secondaryLabelColor
        previewTitle.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(previewTitle)

        previewSummaryLabel.font = .systemFont(ofSize: 11, weight: .regular)
        previewSummaryLabel.textColor = .secondaryLabelColor
        previewSummaryLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(previewSummaryLabel)

        let previewScroll = NSScrollView()
        previewScroll.hasVerticalScroller = true
        previewScroll.translatesAutoresizingMaskIntoConstraints = false
        previewScroll.borderType = .bezelBorder

        let pvTypeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pv_type"))
        pvTypeCol.title = "Type"
        pvTypeCol.width = 70
        previewTableView.addTableColumn(pvTypeCol)

        let pvNameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pv_name"))
        pvNameCol.title = "Name"
        pvNameCol.width = 140
        previewTableView.addTableColumn(pvNameCol)

        let pvPathCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pv_path"))
        pvPathCol.title = "Path"
        pvPathCol.width = 200
        previewTableView.addTableColumn(pvPathCol)

        let pvStackCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pv_stack"))
        pvStackCol.title = "Stack"
        pvStackCol.width = 60
        previewTableView.addTableColumn(pvStackCol)

        previewTableView.rowHeight = 18
        previewTableView.dataSource = self
        previewTableView.delegate = self
        previewTableView.tag = 3
        previewTableView.usesAlternatingRowBackgroundColors = true
        previewScroll.documentView = previewTableView
        contentView.addSubview(previewScroll)

        NSLayoutConstraint.activate([
            // Title row
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            helpBtn.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            helpBtn.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            helpBtn.widthAnchor.constraint(equalToConstant: 20),
            helpBtn.heightAnchor.constraint(equalToConstant: 20),

            // Tree label + scroll
            treeLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            treeLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),

            treeScrollView.topAnchor.constraint(equalTo: treeLabel.bottomAnchor, constant: 4),
            treeScrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            treeScrollView.widthAnchor.constraint(equalToConstant: 300),
            treeScrollView.bottomAnchor.constraint(equalTo: previewTitle.topAnchor, constant: -12),

            // Mapping label + scroll
            mappingLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            mappingLabel.leadingAnchor.constraint(equalTo: treeScrollView.trailingAnchor, constant: 16),

            mappingScroll.topAnchor.constraint(equalTo: mappingLabel.bottomAnchor, constant: 4),
            mappingScroll.leadingAnchor.constraint(equalTo: treeScrollView.trailingAnchor, constant: 16),
            mappingScroll.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            mappingScroll.bottomAnchor.constraint(equalTo: addBtn.topAnchor, constant: -8),

            // Buttons
            addBtn.leadingAnchor.constraint(equalTo: mappingScroll.leadingAnchor),
            addBtn.bottomAnchor.constraint(equalTo: previewTitle.topAnchor, constant: -12),

            removeBtn.leadingAnchor.constraint(equalTo: addBtn.trailingAnchor, constant: 8),
            removeBtn.bottomAnchor.constraint(equalTo: addBtn.bottomAnchor),

            saveBtn.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            saveBtn.bottomAnchor.constraint(equalTo: addBtn.bottomAnchor),

            // Preview section
            previewTitle.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            previewTitle.bottomAnchor.constraint(equalTo: previewSummaryLabel.topAnchor, constant: -2),

            previewSummaryLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            previewSummaryLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            previewSummaryLabel.bottomAnchor.constraint(equalTo: previewScroll.topAnchor, constant: -4),

            previewScroll.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            previewScroll.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            previewScroll.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            previewScroll.heightAnchor.constraint(equalToConstant: 120),
        ])
    }

    // MARK: - Actions

    @objc private func addMappingClicked(_ sender: NSButton) {
        // Smart defaults: derive from selected file tree node or duplicate selected mapping
        let selectedMappingRow = mappingTableView.selectedRow
        if selectedMappingRow >= 0, selectedMappingRow < mappingRows.count {
            let source = mappingRows[selectedMappingRow]
            mappingRows.append(MappingRow(path: source.path, type: source.type, stack: source.stack))
        } else {
            let clickedRow = fileOutlineView.selectedRow
            if clickedRow >= 0, let node = fileOutlineView.item(atRow: clickedRow) as? FileTreeNode {
                let glob = deriveGlob(for: node)
                mappingRows.append(MappingRow(path: glob, type: "skill", stack: "common"))
            } else {
                mappingRows.append(MappingRow(path: "", type: "skill", stack: "common"))
            }
        }
        mappingTableView.reloadData()
        updateMatchHighlights()
    }

    @objc private func removeMappingClicked(_ sender: NSButton) {
        let idx = mappingTableView.selectedRow
        guard idx >= 0, idx < mappingRows.count else { return }
        mappingRows.remove(at: idx)
        mappingTableView.reloadData()
        updateMatchHighlights()
    }

    @objc private func saveClicked(_ sender: NSButton) {
        let pathMappings = mappingRows.map { row in
            PathMapping(path: row.path, type: row.type, stack: row.stack)
        }
        let mapping = RegistryMapping(version: 1, root: nil, mappings: pathMappings, fileTransforms: nil)
        RegistryMappingResolver.saveMapping(mapping, registryName: registryName)

        // Re-resolve components after save
        let resolved = RegistryMappingResolver.resolveMapping(mapping, repoPath: repoPath)
        RegistryManager.shared.mappedComponents[registryName] = resolved
        RegistryManager.shared.mappingModes[registryName] = .localMapping

        // Notify that components changed
        NotificationCenter.default.post(name: RegistryManager.componentsDidChange, object: nil)

        window?.close()
    }

    @objc private func showGlobHelp(_ sender: NSButton) {
        let popover = NSPopover()
        popover.behavior = .transient

        let helpText = """
        Glob Pattern Reference

        *           any file in a directory
        **          recursive (all subdirectories)
        *.md        all .md files in a directory
        **/*.md     all .md files recursively
        skills/**   everything under skills/
        skills/*/SKILL.md   skill entry files
        """

        let vc = NSViewController()
        let tf = NSTextField(labelWithString: helpText)
        tf.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tf.translatesAutoresizingMaskIntoConstraints = false
        vc.view = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 150))
        vc.view.addSubview(tf)
        NSLayoutConstraint.activate([
            tf.topAnchor.constraint(equalTo: vc.view.topAnchor, constant: 12),
            tf.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor, constant: 12),
            tf.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor, constant: -12),
            tf.bottomAnchor.constraint(equalTo: vc.view.bottomAnchor, constant: -12),
        ])
        popover.contentViewController = vc
        popover.contentSize = NSSize(width: 280, height: 150)
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    // MARK: - Match Highlighting

    private func updateMatchHighlights() {
        // Clear all highlights
        for node in fileTreeNodes { node.clearMatches() }

        let pathMappings = mappingRows.map { row in
            PathMapping(path: row.path, type: row.type, stack: row.stack)
        }
        let mapping = RegistryMapping(version: 1, root: nil, mappings: pathMappings, fileTransforms: nil)
        resolvedDetailed = RegistryMappingResolver.resolveMappingDetailed(mapping, repoPath: repoPath)

        // Build path → (type, mappingIndex) lookup
        var matchMap: [String: (type: ComponentType, index: Int)] = [:]
        for entry in resolvedDetailed {
            let relPath = entry.component.fileURL.path.replacingOccurrences(of: repoPath.path + "/", with: "")
            matchMap[relPath] = (type: entry.component.type, index: entry.mappingIndex)
        }

        // Walk tree and apply matches
        func applyMatches(to nodes: [FileTreeNode]) {
            for node in nodes {
                if let match = matchMap[node.relativePath] {
                    node.matchedType = match.type
                    node.matchedMappingIndex = match.index
                }
                if node.isDirectory {
                    applyMatches(to: node.children)
                }
            }
        }
        applyMatches(to: fileTreeNodes)
        for node in fileTreeNodes { node.propagateMatches() }

        fileOutlineView.reloadData()
        updatePreviewTable()
    }

    private func updatePreviewTable() {
        previewTableView.reloadData()

        var counts: [String: Int] = [:]
        for entry in resolvedDetailed {
            counts[entry.component.type.pluralLabel, default: 0] += 1
        }

        if resolvedDetailed.isEmpty {
            previewSummaryLabel.stringValue = "No components resolved. Add mapping entries above."
        } else {
            let parts = counts.sorted(by: { $0.key < $1.key }).map { "\($0.value) \($0.key)" }
            previewSummaryLabel.stringValue = "Resolved \(resolvedDetailed.count) components: \(parts.joined(separator: ", "))"
        }
    }

    // MARK: - Context Menu Helpers

    private func deriveGlob(for node: FileTreeNode) -> String {
        if node.isDirectory {
            return node.relativePath + "/**"
        } else {
            return node.relativePath
        }
    }

    private func addMapping(glob: String, type: String) {
        mappingRows.append(MappingRow(path: glob, type: type, stack: "common"))
        mappingTableView.reloadData()
        updateMatchHighlights()
    }
}

// MARK: - NSOutlineViewDataSource & NSOutlineViewDelegate (File Tree)

extension MappingEditorWindow: NSOutlineViewDataSource, NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let node = item as? FileTreeNode {
            return node.children.count
        }
        return fileTreeNodes.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? FileTreeNode {
            return node.children[index]
        }
        return fileTreeNodes[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? FileTreeNode else { return false }
        return node.isDirectory && !node.children.isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileTreeNode else { return nil }

        let cellID = NSUserInterfaceItemIdentifier("FileTreeCell")
        let cellView: NSTableCellView
        if let existing = outlineView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView {
            cellView = existing
        } else {
            cellView = NSTableCellView()
            cellView.identifier = cellID

            let iv = NSImageView()
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.imageScaling = .scaleProportionallyDown
            cellView.addSubview(iv)
            cellView.imageView = iv

            let tf = NSTextField(labelWithString: "")
            tf.isEditable = false
            tf.isBordered = false
            tf.drawsBackground = false
            tf.lineBreakMode = .byClipping
            tf.translatesAutoresizingMaskIntoConstraints = false
            cellView.addSubview(tf)
            cellView.textField = tf

            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: cellView.leadingAnchor),
                iv.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 14),
                iv.heightAnchor.constraint(equalToConstant: 14),
                tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 4),
                tf.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
                tf.trailingAnchor.constraint(lessThanOrEqualTo: cellView.trailingAnchor, constant: -2),
            ])
        }

        let monoFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

        // Determine dimming for per-row highlighting
        let shouldDim: Bool
        if let selected = selectedMappingIndex {
            if let nodeIdx = node.matchedMappingIndex {
                shouldDim = (nodeIdx != selected)
            } else {
                shouldDim = true
            }
        } else {
            shouldDim = false
        }

        let alpha: CGFloat = shouldDim ? 0.3 : 1.0

        if node.isDirectory {
            let img = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
            cellView.imageView?.image = img
            cellView.textField?.font = monoFont

            if let matchType = node.matchedType {
                let color = typeColors[matchType] ?? .secondaryLabelColor
                cellView.imageView?.contentTintColor = color.withAlphaComponent(alpha)
                cellView.textField?.textColor = NSColor.secondaryLabelColor.withAlphaComponent(alpha)

                let dot: String
                switch matchType {
                case .skill: dot = " \u{1F535}"
                case .rule: dot = " \u{1F7E2}"
                case .prompt: dot = " \u{1F7E0}"
                case .agent: dot = " \u{1F7E3}"
                case .hook: dot = " \u{1F534}"
                case .mcpServer: dot = " \u{26AB}"
                }
                cellView.textField?.stringValue = node.name + "/" + dot
            } else {
                cellView.imageView?.contentTintColor = NSColor.secondaryLabelColor.withAlphaComponent(alpha)
                cellView.textField?.stringValue = node.name + "/"
                cellView.textField?.textColor = NSColor.secondaryLabelColor.withAlphaComponent(alpha)
            }
        } else {
            let symbolName = "doc"
            let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            cellView.imageView?.image = img

            if let matchType = node.matchedType {
                let color = typeColors[matchType] ?? .labelColor
                cellView.imageView?.contentTintColor = color.withAlphaComponent(alpha)
                cellView.textField?.textColor = NSColor.labelColor.withAlphaComponent(alpha)

                // Append colored dot
                let dot: String
                switch matchType {
                case .skill: dot = " \u{1F535}"      // blue circle
                case .rule: dot = " \u{1F7E2}"       // green circle
                case .prompt: dot = " \u{1F7E0}"     // orange circle
                case .agent: dot = " \u{1F7E3}"      // purple circle
                case .hook: dot = " \u{1F534}"       // red circle
                case .mcpServer: dot = " \u{26AB}"    // black circle (teal not available)
                }
                cellView.textField?.stringValue = node.name + dot
            } else {
                cellView.imageView?.contentTintColor = NSColor.secondaryLabelColor.withAlphaComponent(alpha)
                cellView.textField?.textColor = NSColor.secondaryLabelColor.withAlphaComponent(alpha)
                cellView.textField?.stringValue = node.name
            }
            cellView.textField?.font = monoFont
        }

        return cellView
    }
}

// MARK: - NSMenuDelegate (Context Menu)

extension MappingEditorWindow: NSMenuDelegate {

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let clickedRow = fileOutlineView.clickedRow
        guard clickedRow >= 0, let node = fileOutlineView.item(atRow: clickedRow) as? FileTreeNode else { return }

        let types: [(label: String, type: String, globSuffix: String)]
        if node.isDirectory {
            types = [
                ("Map as Skills", "skill", "/**"),
                ("Map as Rules", "rule", "/**/*.md"),
                ("Map as Prompts", "prompt", "/**"),
                ("Map as Hooks", "hook", "/**"),
                ("Map as Agents", "agent", "/**"),
                ("Map as MCP Servers", "mcp-server", "/**"),
            ]
        } else {
            types = [
                ("Map as Skill", "skill", ""),
                ("Map as Rule", "rule", ""),
                ("Map as Prompt", "prompt", ""),
                ("Map as Hook", "hook", ""),
                ("Map as Agent", "agent", ""),
                ("Map as MCP Server", "mcp-server", ""),
            ]
        }

        for entry in types {
            let glob: String
            if node.isDirectory {
                glob = node.relativePath + entry.globSuffix
            } else {
                glob = node.relativePath
            }

            let item = NSMenuItem(title: entry.label + " (\(glob))", action: #selector(contextMenuMapAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = (glob, entry.type)
            menu.addItem(item)
        }
    }

    @objc private func contextMenuMapAction(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? (String, String) else { return }
        addMapping(glob: info.0, type: info.1)
    }
}

// MARK: - NSTableViewDataSource & Delegate (Mappings + Preview)

extension MappingEditorWindow: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView.tag == 2 { return mappingRows.count }
        if tableView.tag == 3 { return resolvedDetailed.count }
        return 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView.tag == 2 {
            return mappingCellView(tableColumn: tableColumn, row: row)
        }
        if tableView.tag == 3 {
            return previewCellView(tableColumn: tableColumn, row: row)
        }
        return nil
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if tableView.tag == 2 { return 24 }
        if tableView.tag == 3 { return 18 }
        return 20
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tableView = notification.object as? NSTableView else { return }
        if tableView.tag == 2 {
            let idx = tableView.selectedRow
            selectedMappingIndex = idx >= 0 ? idx : nil
            fileOutlineView.reloadData()
        }
    }

    // MARK: Mapping Table Cells

    private func mappingCellView(tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < mappingRows.count else { return nil }
        let entry = mappingRows[row]

        switch tableColumn?.identifier.rawValue {
        case "map_path":
            let field = NSTextField()
            field.stringValue = entry.path
            field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            field.isBordered = true
            field.isEditable = true
            field.delegate = self
            field.tag = row * 10 + 0
            field.placeholderString = "e.g. skills/**"
            return field

        case "map_type":
            let popup = NSPopUpButton()
            popup.addItems(withTitles: ["skill", "rule", "prompt", "agent", "mcp-server", "hook"])
            popup.selectItem(withTitle: entry.type)
            popup.font = .systemFont(ofSize: 11)
            popup.tag = row * 10 + 1
            popup.target = self
            popup.action = #selector(typePopupChanged(_:))
            return popup

        case "map_stack":
            let field = NSTextField()
            field.stringValue = entry.stack
            field.font = .systemFont(ofSize: 11)
            field.isBordered = true
            field.isEditable = true
            field.delegate = self
            field.tag = row * 10 + 2
            return field

        default:
            return nil
        }
    }

    // MARK: Preview Table Cells

    private func previewCellView(tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < resolvedDetailed.count else { return nil }
        let entry = resolvedDetailed[row]
        let comp = entry.component
        let relPath = comp.fileURL.path.replacingOccurrences(of: repoPath.path + "/", with: "")

        switch tableColumn?.identifier.rawValue {
        case "pv_type":
            let tf = NSTextField(labelWithString: comp.type.rawValue)
            tf.font = .systemFont(ofSize: 10, weight: .medium)
            tf.textColor = typeColors[comp.type] ?? .labelColor
            return tf

        case "pv_name":
            let tf = NSTextField(labelWithString: comp.name)
            tf.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            tf.lineBreakMode = .byTruncatingTail
            return tf

        case "pv_path":
            let tf = NSTextField(labelWithString: relPath)
            tf.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            tf.textColor = .secondaryLabelColor
            tf.lineBreakMode = .byTruncatingMiddle
            return tf

        case "pv_stack":
            let tf = NSTextField(labelWithString: comp.stack)
            tf.font = .systemFont(ofSize: 10)
            tf.textColor = .secondaryLabelColor
            return tf

        default:
            return nil
        }
    }

    @objc private func typePopupChanged(_ sender: NSPopUpButton) {
        let row = sender.tag / 10
        guard row < mappingRows.count, let title = sender.selectedItem?.title else { return }
        mappingRows[row].type = title
        updateMatchHighlights()
    }
}

// MARK: - NSTextFieldDelegate for editable cells

extension MappingEditorWindow: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        let row = field.tag / 10
        let col = field.tag % 10
        guard row < mappingRows.count else { return }

        switch col {
        case 0: mappingRows[row].path = field.stringValue
        case 2: mappingRows[row].stack = field.stringValue
        default: break
        }
        updateMatchHighlights()
    }
}
