import AppKit

class ManageWorktreesWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {

    private static var shared: ManageWorktreesWindow?

    static func show() {
        if let existing = shared {
            existing.window?.makeKeyAndOrderFront(nil)
            existing.refreshAll()
            NSApp.runModal(for: existing.window!)
            return
        }
        let controller = ManageWorktreesWindow()
        shared = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: controller.window!)
    }

    private let tableView = NSTableView()
    private let totalLabel = NSTextField(labelWithString: "")
    private let removeButton: NSButton
    private let removeAllCleanButton: NSButton
    private let refreshButton: NSButton
    private let spinner = NSProgressIndicator()

    private var worktrees: [GitWorktreeManager.WorktreeDetail] = []

    init() {
        removeButton = NSButton(title: "Remove", target: nil, action: nil)
        removeAllCleanButton = NSButton(title: "Remove All Clean", target: nil, action: nil)
        refreshButton = NSButton(title: "Refresh", target: nil, action: nil)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 750, height: 450),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Manage Worktrees"
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 600, height: 300)

        super.init(window: window)
        window.delegate = self

        removeButton.target = self
        removeButton.action = #selector(removeSelected(_:))
        removeButton.isEnabled = false

        removeAllCleanButton.target = self
        removeAllCleanButton.action = #selector(removeAllClean(_:))

        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked(_:))

        setupUI()
        refreshAll()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        // Table columns
        let repoCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("repo"))
        repoCol.title = "Repo"
        repoCol.width = 150
        repoCol.minWidth = 80
        tableView.addTableColumn(repoCol)

        let branchCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("branch"))
        branchCol.title = "Branch"
        branchCol.width = 140
        branchCol.minWidth = 80
        tableView.addTableColumn(branchCol)

        let sizeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        sizeCol.title = "Size"
        sizeCol.width = 80
        sizeCol.minWidth = 50
        tableView.addTableColumn(sizeCol)

        let statusCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("status"))
        statusCol.title = "Status"
        statusCol.width = 70
        statusCol.minWidth = 50
        tableView.addTableColumn(statusCol)

        let inUseCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("inuse"))
        inUseCol.title = "In Use"
        inUseCol.width = 50
        inUseCol.minWidth = 40
        tableView.addTableColumn(inUseCol)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.headerView = NSTableHeaderView()

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scrollView)

        // Bottom bar
        let bottomBar = NSView()
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(bottomBar)

        totalLabel.translatesAutoresizingMaskIntoConstraints = false
        totalLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bottomBar.addSubview(totalLabel)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.isHidden = true
        bottomBar.addSubview(spinner)

        removeButton.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(removeButton)

        removeAllCleanButton.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(removeAllCleanButton)

        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(refreshButton)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -8),

            bottomBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            bottomBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            bottomBar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            bottomBar.heightAnchor.constraint(equalToConstant: 30),

            totalLabel.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor),
            totalLabel.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),

            spinner.leadingAnchor.constraint(equalTo: totalLabel.trailingAnchor, constant: 8),
            spinner.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),

            refreshButton.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor),
            refreshButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),

            removeAllCleanButton.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -8),
            removeAllCleanButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),

            removeButton.trailingAnchor.constraint(equalTo: removeAllCleanButton.leadingAnchor, constant: -8),
            removeButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
        ])
    }

    private func refreshAll() {
        spinner.isHidden = false
        spinner.startAnimation(nil)
        removeButton.isEnabled = false
        removeAllCleanButton.isEnabled = false

        GitWorktreeManager.shared.enumerateAllWorktrees { [weak self] details in
            guard let self else { return }
            self.worktrees = details
            self.tableView.reloadData()
            self.updateTotals()
            self.spinner.stopAnimation(nil)
            self.spinner.isHidden = true
            self.updateButtonStates()
        }
    }

    private func updateTotals() {
        let totalBytes = worktrees.reduce(UInt64(0)) { $0 + $1.diskSizeBytes }
        let count = worktrees.count
        totalLabel.stringValue = "Total: \(formatSize(totalBytes)) across \(count) worktree\(count == 1 ? "" : "s")"
    }

    private func updateButtonStates() {
        let sel = tableView.selectedRow
        if sel >= 0 && sel < worktrees.count {
            removeButton.isEnabled = !worktrees[sel].isOpenInTab
        } else {
            removeButton.isEnabled = false
        }
        let hasRemovable = worktrees.contains { !$0.isDirty && !$0.isOpenInTab }
        removeAllCleanButton.isEnabled = hasRemovable
    }

    private func formatSize(_ bytes: UInt64) -> String {
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        let gb = mb / 1024
        return String(format: "%.2f GB", gb)
    }

    // MARK: - Actions

    @objc private func removeSelected(_ sender: Any?) {
        let sel = tableView.selectedRow
        guard sel >= 0 && sel < worktrees.count else { return }
        let detail = worktrees[sel]
        guard !detail.isOpenInTab else { return }

        let alert = NSAlert.branded()
        alert.messageText = "Remove Worktree?"
        alert.informativeText = "This will permanently remove the worktree at \(detail.info.branchName ?? detail.info.worktreeRoot) and delete its branch."
        if detail.isDirty {
            alert.informativeText += "\n\nThis worktree has uncommitted changes that will be lost."
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        GitWorktreeManager.shared.forceRemoveWorktree(detail.info)
        refreshAll()
    }

    @objc private func removeAllClean(_ sender: Any?) {
        let removable = worktrees.filter { !$0.isDirty && !$0.isOpenInTab }
        guard !removable.isEmpty else { return }

        let alert = NSAlert.branded()
        alert.messageText = "Remove \(removable.count) Clean Worktree\(removable.count == 1 ? "" : "s")?"
        alert.informativeText = "This will permanently remove all clean worktrees that are not currently open in a tab."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove All Clean")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        for detail in removable {
            GitWorktreeManager.shared.forceRemoveWorktree(detail.info)
        }
        refreshAll()
    }

    @objc private func refreshClicked(_ sender: Any?) {
        refreshAll()
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        return worktrees.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < worktrees.count, let column = tableColumn else { return nil }
        let detail = worktrees[row]

        let id = column.identifier
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField
            ?? {
                let tf = NSTextField(labelWithString: "")
                tf.identifier = id
                tf.lineBreakMode = .byTruncatingTail
                return tf
            }()

        switch id.rawValue {
        case "repo":
            let repoName = (detail.info.repoRoot as NSString).lastPathComponent
            cell.stringValue = repoName
        case "branch":
            cell.stringValue = detail.info.branchName ?? "—"
        case "size":
            cell.stringValue = formatSize(detail.diskSizeBytes)
        case "status":
            if detail.isDirty {
                cell.stringValue = "Dirty"
                cell.textColor = .systemRed
            } else {
                cell.stringValue = "Clean"
                cell.textColor = .systemGreen
            }
        case "inuse":
            cell.stringValue = detail.isOpenInTab ? "✓" : ""
            cell.textColor = .labelColor
        default:
            break
        }

        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtonStates()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        NSApp.stopModal()
        ManageWorktreesWindow.shared = nil
    }
}
