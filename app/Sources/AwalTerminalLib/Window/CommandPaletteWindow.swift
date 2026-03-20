import AppKit

/// Floating command palette for quick action discovery and execution.
class CommandPaletteWindow: NSWindowController, NSWindowDelegate, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {

    private static var shared: CommandPaletteWindow?

    static func toggle() {
        if let existing = shared, existing.window?.isVisible == true {
            existing.window?.close()
        } else {
            show()
        }
    }

    static func show() {
        if let existing = shared {
            existing.window?.makeKeyAndOrderFront(nil)
            existing.searchField.stringValue = ""
            existing.filterActions("")
            existing.window?.makeFirstResponder(existing.searchField)
            return
        }
        let controller = CommandPaletteWindow()
        shared = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Action Registry

    struct PaletteAction {
        let id: String
        let title: String
        let shortcut: String?
        let handler: () -> Void
    }

    private var allActions: [PaletteAction] = []
    private var filteredActions: [PaletteAction] = []
    private var selectedIndex: Int = 0

    // MARK: - UI

    private let searchField: NSTextField = {
        let field = NSTextField()
        field.placeholderString = "Type a command..."
        field.font = NSFont.systemFont(ofSize: 16)
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = false
        field.textColor = NSColor.white
        return field
    }()

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.backgroundColor = NSColor(white: 0.12, alpha: 0.98)
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true

        // Center horizontally, position near top of screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - 280
            let y = screenFrame.maxY - 200
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        super.init(window: panel)
        panel.delegate = self

        setupUI()
        populateActions()
        filterActions("")
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        Self.shared = nil
    }

    // MARK: - UI Setup

    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true

        // Search field container
        let searchContainer = NSView()
        searchContainer.translatesAutoresizingMaskIntoConstraints = false
        searchContainer.wantsLayer = true
        searchContainer.layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
        contentView.addSubview(searchContainer)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.delegate = self
        searchContainer.addSubview(searchField)

        // Separator
        let separator = NSView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
        contentView.addSubview(separator)

        // Table view for results
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("action"))
        column.width = 520
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = 32
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.selectionHighlightStyle = .none
        tableView.target = self
        tableView.doubleAction = #selector(executeSelected)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        contentView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            searchContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
            searchContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            searchContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            searchContainer.heightAnchor.constraint(equalToConstant: 44),

            searchField.leadingAnchor.constraint(equalTo: searchContainer.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: searchContainer.trailingAnchor, constant: -16),
            searchField.centerYAnchor.constraint(equalTo: searchContainer.centerYAnchor),

            separator.topAnchor.constraint(equalTo: searchContainer.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    // MARK: - Actions

    private func populateActions() {
        allActions = []

        // Collect from the main menu structure
        guard let mainMenu = NSApplication.shared.mainMenu else { return }
        collectMenuActions(mainMenu, prefix: nil)
    }

    private func collectMenuActions(_ menu: NSMenu, prefix: String?) {
        for item in menu.items {
            if item.isSeparatorItem { continue }
            if let submenu = item.submenu {
                collectMenuActions(submenu, prefix: submenu.title)
                continue
            }
            guard item.action != nil else { continue }
            guard item.isEnabled || item.target != nil else { continue }

            let title: String
            if let p = prefix {
                title = "\(p): \(item.title)"
            } else {
                title = item.title
            }

            let shortcut = formatShortcut(item)

            let menuItem = item
            allActions.append(PaletteAction(
                id: title,
                title: title,
                shortcut: shortcut,
                handler: { [weak menuItem] in
                    guard let item = menuItem else { return }
                    NSApp.sendAction(item.action!, to: item.target, from: item)
                }
            ))
        }
    }

    private func formatShortcut(_ item: NSMenuItem) -> String? {
        guard !item.keyEquivalent.isEmpty else { return nil }
        var parts: [String] = []
        let mods = item.keyEquivalentModifierMask
        if mods.contains(.control) { parts.append("^") }
        if mods.contains(.option) { parts.append("\u{2325}") }
        if mods.contains(.shift) { parts.append("\u{21E7}") }
        if mods.contains(.command) { parts.append("\u{2318}") }
        parts.append(item.keyEquivalent.uppercased())
        return parts.joined()
    }

    // MARK: - Fuzzy Search

    private func filterActions(_ query: String) {
        if query.isEmpty {
            filteredActions = allActions
        } else {
            let lower = query.lowercased()
            filteredActions = allActions
                .map { action -> (PaletteAction, Int) in
                    let title = action.title.lowercased()
                    // Exact substring match gets highest score
                    if title.contains(lower) {
                        let pos = title.range(of: lower)!.lowerBound.utf16Offset(in: title)
                        return (action, 1000 - pos)
                    }
                    // Word boundary fuzzy match
                    let score = fuzzyScore(query: lower, target: title)
                    return (action, score)
                }
                .filter { $0.1 > 0 }
                .sorted { $0.1 > $1.1 }
                .map { $0.0 }
        }
        selectedIndex = 0
        tableView.reloadData()
        if !filteredActions.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    private func fuzzyScore(query: String, target: String) -> Int {
        var score = 0
        var targetIdx = target.startIndex
        for qChar in query {
            guard let found = target[targetIdx...].firstIndex(of: qChar) else { return 0 }
            score += 1
            // Bonus for word boundary match
            if found == target.startIndex || target[target.index(before: found)] == " " || target[target.index(before: found)] == ":" {
                score += 5
            }
            targetIdx = target.index(after: found)
        }
        return score
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        filterActions(searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(moveUp(_:)) {
            if selectedIndex > 0 {
                selectedIndex -= 1
                tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
                tableView.scrollRowToVisible(selectedIndex)
            }
            return true
        }
        if commandSelector == #selector(moveDown(_:)) {
            if selectedIndex < filteredActions.count - 1 {
                selectedIndex += 1
                tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
                tableView.scrollRowToVisible(selectedIndex)
            }
            return true
        }
        if commandSelector == #selector(insertNewline(_:)) {
            executeSelected()
            return true
        }
        if commandSelector == #selector(cancelOperation(_:)) {
            window?.close()
            return true
        }
        return false
    }

    @objc private func executeSelected() {
        guard selectedIndex >= 0 && selectedIndex < filteredActions.count else { return }
        let action = filteredActions[selectedIndex]
        window?.close()
        // Slight delay to let the palette close before executing
        DispatchQueue.main.async {
            action.handler()
        }
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredActions.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filteredActions.count else { return nil }
        let action = filteredActions[row]

        let cellView = NSView()

        let titleLabel = NSTextField(labelWithString: action.title)
        titleLabel.font = NSFont.systemFont(ofSize: 13)
        titleLabel.textColor = NSColor.white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        cellView.addSubview(titleLabel)

        let shortcutLabel = NSTextField(labelWithString: action.shortcut ?? "")
        shortcutLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        shortcutLabel.textColor = NSColor(white: 0.5, alpha: 1)
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        shortcutLabel.setContentHuggingPriority(.required, for: .horizontal)
        cellView.addSubview(shortcutLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 16),
            titleLabel.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: shortcutLabel.leadingAnchor, constant: -8),

            shortcutLabel.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -16),
            shortcutLabel.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
        ])

        // Highlight selected row
        cellView.wantsLayer = true
        if row == selectedIndex {
            cellView.layer?.backgroundColor = NSColor(white: 1, alpha: 0.1).cgColor
            cellView.layer?.cornerRadius = 4
        }

        return cellView
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        32
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        if row >= 0 {
            selectedIndex = row
            tableView.reloadData()
        }
    }
}
