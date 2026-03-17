import AppKit

/// Dashboard window aggregating all active AI agents across tabs/windows
/// with real-time status, spend, and kill switches.
class MissionControlWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {

    private static var shared: MissionControlWindow?

    static func show() {
        if let existing = shared {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = MissionControlWindow()
        shared = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    static func toggle() {
        if let existing = shared, existing.window?.isVisible == true {
            existing.window?.close()
        } else {
            show()
        }
    }

    // MARK: - Data

    struct AgentRow {
        let windowController: TerminalWindowController
        let tabIndex: Int
        let tab: TabState
        let terminal: TerminalView

        var isGenerating: Bool { terminal.isGenerating }
        var modelName: String { tab.statusBar.currentModelName }
        var workingDir: String { tab.statusBar.currentPath ?? "" }
        var phase: String { terminal.isGenerating ? terminal.generationPhase : "Idle" }
        var isDanger: Bool { tab.isDangerMode }
    }

    private var rows: [AgentRow] = []
    private var refreshTimer: Timer?

    // MARK: - UI

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    // Header
    private let totalCostLabel = NSTextField(labelWithString: "")
    private let totalTokensLabel = NSTextField(labelWithString: "")
    private let activeAgentLabel = NSTextField(labelWithString: "")

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Mission Control"
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 600, height: 300)
        window.backgroundColor = NSColor(white: 0.12, alpha: 1.0)

        super.init(window: window)
        window.delegate = self

        setupUI()
        refreshData()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refreshData()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        Self.shared = nil
    }

    // MARK: - UI Setup

    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true

        // Header bar
        let headerView = NSView()
        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.wantsLayer = true
        headerView.layer?.backgroundColor = NSColor(white: 0.08, alpha: 1.0).cgColor
        contentView.addSubview(headerView)

        for label in [totalCostLabel, totalTokensLabel, activeAgentLabel] {
            label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
            label.textColor = NSColor(white: 0.7, alpha: 1.0)
            label.translatesAutoresizingMaskIntoConstraints = false
            headerView.addSubview(label)
        }

        // Table
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        contentView.addSubview(scrollView)

        tableView.headerView = NSTableHeader()
        tableView.backgroundColor = .clear
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.rowHeight = 32
        tableView.style = .plain
        tableView.dataSource = self
        tableView.delegate = self
        tableView.gridStyleMask = [.solidHorizontalGridLineMask]
        tableView.gridColor = NSColor(white: 0.2, alpha: 1.0)

        let columns: [(String, String, CGFloat)] = [
            ("status", "", 24),
            ("model", "Model", 90),
            ("dir", "Directory", 120),
            ("phase", "Phase", 130),
            ("tokens", "Tokens", 120),
            ("cost", "Cost", 70),
            ("elapsed", "Elapsed", 70),
            ("kill", "", 50),
        ]

        for (id, title, width) in columns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = title
            col.width = width
            col.minWidth = id == "status" ? 24 : 40
            if id == "dir" || id == "phase" {
                col.resizingMask = .autoresizingMask
            }
            tableView.addTableColumn(col)
        }

        scrollView.documentView = tableView

        // Constraints
        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 36),

            totalCostLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 12),
            totalCostLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

            totalTokensLabel.centerXAnchor.constraint(equalTo: headerView.centerXAnchor),
            totalTokensLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

            activeAgentLabel.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -12),
            activeAgentLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    // MARK: - Data Collection

    private func refreshData() {
        rows.removeAll()

        for controller in TerminalWindowTracker.shared.allControllers {
            for (index, tab) in controller.tabs.enumerated() {
                let terminal = tab.splitContainer.focusedTerminal
                // Only show tabs with an active AI session (not plain Shell)
                let model = tab.statusBar.currentModelName
                guard !model.isEmpty && model != "Shell" else { continue }
                rows.append(AgentRow(
                    windowController: controller,
                    tabIndex: index,
                    tab: tab,
                    terminal: terminal
                ))
            }
        }

        // Update header
        var totalCost: Double = 0
        var totalIn = 0
        var totalOut = 0
        var activeCount = 0

        for row in rows {
            let tracker = row.tab.tokenTracker
            totalCost += tracker.estimatedCost
            totalIn += tracker.currentInput
            totalOut += tracker.totalOutput
            if row.isGenerating { activeCount += 1 }
        }

        totalCostLabel.stringValue = String(format: "Total: $%.4f", totalCost)
        totalTokensLabel.stringValue = "\(formatTokenCount(totalIn)) in · \(formatTokenCount(totalOut)) out"
        activeAgentLabel.stringValue = "\(activeCount) active / \(rows.count) agents"

        if totalCost > 1.0 {
            totalCostLabel.textColor = NSColor(red: 1.0, green: 0.6, blue: 0.3, alpha: 1.0)
        } else {
            totalCostLabel.textColor = NSColor(white: 0.7, alpha: 1.0)
        }

        tableView.reloadData()
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count, let colId = tableColumn?.identifier.rawValue else { return nil }
        let agent = rows[row]

        switch colId {
        case "status":
            return makeStatusDot(agent)
        case "model":
            return makeLabel(agent.modelName)
        case "dir":
            return makeLabel((agent.workingDir as NSString).lastPathComponent)
        case "phase":
            return makeLabel(agent.phase)
        case "tokens":
            let tracker = agent.tab.tokenTracker
            return makeLabel("\(formatTokenCount(tracker.currentInput)) ctx / \(formatTokenCount(tracker.totalOutput)) out")
        case "cost":
            let cost = agent.tab.tokenTracker.estimatedCost
            let label = makeLabel(String(format: "$%.3f", cost))
            if cost > 0.5 {
                (label.subviews.first as? NSTextField)?.textColor = NSColor(red: 1.0, green: 0.6, blue: 0.3, alpha: 1.0)
            }
            return label
        case "elapsed":
            if let start = agent.tab.sessionStartTime {
                let elapsed = Int(Date().timeIntervalSince(start))
                let m = elapsed / 60
                let s = elapsed % 60
                return makeLabel(String(format: "%d:%02d", m, s))
            }
            return makeLabel("—")
        case "kill":
            return makeKillButton(row)
        default:
            return nil
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = NSTableRowView()
        rowView.wantsLayer = true
        if row < rows.count && rows[row].isGenerating {
            rowView.backgroundColor = NSColor(red: 0.1, green: 0.15, blue: 0.1, alpha: 1.0)
        } else {
            rowView.backgroundColor = .clear
        }
        return rowView
    }

    // MARK: - Cell Factories

    private func makeLabel(_ text: String) -> NSView {
        let cell = NSView()
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = NSColor(white: 0.85, alpha: 1.0)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func makeStatusDot(_ agent: AgentRow) -> NSView {
        let cell = NSView()
        let dot = NSView()
        dot.wantsLayer = true
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.layer?.cornerRadius = 5

        if agent.isDanger {
            dot.layer?.backgroundColor = NSColor.orange.cgColor
        } else if agent.isGenerating {
            dot.layer?.backgroundColor = NSColor(red: 0.3, green: 0.85, blue: 0.4, alpha: 1.0).cgColor
        } else {
            dot.layer?.backgroundColor = NSColor(white: 0.4, alpha: 1.0).cgColor
        }

        cell.addSubview(dot)
        NSLayoutConstraint.activate([
            dot.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
        ])
        return cell
    }

    private func makeKillButton(_ row: Int) -> NSView {
        let cell = NSView()
        let btn = NSButton(title: "Kill", target: self, action: #selector(killAgent(_:)))
        btn.tag = row
        btn.bezelStyle = .inline
        btn.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        btn.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(btn)
        NSLayoutConstraint.activate([
            btn.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
            btn.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    @objc private func killAgent(_ sender: NSButton) {
        let row = sender.tag
        guard row < rows.count else { return }
        let agent = rows[row]

        let alert = NSAlert()
        alert.messageText = "Kill Agent?"
        alert.informativeText = "This will terminate the \(agent.modelName) session in \((agent.workingDir as NSString).lastPathComponent)."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Kill")
        alert.addButton(withTitle: "Cancel")

        guard let window = self.window else { return }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                agent.terminal.cleanup()
            }
        }
    }

    // MARK: - Helpers

    private func formatTokenCount(_ n: Int) -> String {
        if n >= 1_000_000 {
            return String(format: "%.1fM", Double(n) / 1_000_000.0)
        } else if n >= 1_000 {
            return String(format: "%.1fk", Double(n) / 1_000.0)
        }
        return "\(n)"
    }
}

/// Minimal NSTableHeaderView subclass to style the header row.
private class NSTableHeader: NSTableHeaderView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.15, alpha: 1.0).setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
    }
}
