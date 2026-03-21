import AppKit

/// Editor window for managing custom security scanning rules.
/// Rules are persisted to config.toml under [ai_components.security_rules.<name>].
class SecurityRulesEditorWindow: NSWindowController, NSWindowDelegate {

    private static var shared: SecurityRulesEditorWindow?

    static func show() {
        if let existing = shared {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.runModal(for: existing.window!)
            return
        }
        let controller = SecurityRulesEditorWindow()
        shared = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: controller.window!)
    }

    private let tableView = NSTableView()
    private var rules: [RuleRow] = []

    private struct RuleRow {
        var name: String
        var regex: String
        var severity: String  // "warning" | "critical"
        var target: String    // "all" | "hook" | "markdown" | "mcp"
        var description: String
        var isBuiltIn: Bool = false
        var isEnabled: Bool = true
    }

    private static let builtInRules: [RuleRow] = [
        // Hook - Critical
        RuleRow(name: "curl|wget piped to shell", regex: "(curl|wget|nc|ncat)\\s.*\\|\\s*(sh|bash|zsh)", severity: "critical", target: "hook", description: "Network fetch piped to shell", isBuiltIn: true),
        RuleRow(name: "rm -rf /", regex: "rm\\s+-rf\\s+/", severity: "critical", target: "hook", description: "Recursive delete from root", isBuiltIn: true),
        RuleRow(name: "rm -rf ~", regex: "rm\\s+-rf\\s+~", severity: "critical", target: "hook", description: "Recursive delete home directory", isBuiltIn: true),
        RuleRow(name: "rm -rf $HOME", regex: "rm\\s+-rf\\s+\\$HOME", severity: "critical", target: "hook", description: "Recursive delete $HOME", isBuiltIn: true),
        RuleRow(name: "eval with variable", regex: "eval\\s.*\\$", severity: "critical", target: "hook", description: "Eval with variable expansion", isBuiltIn: true),
        RuleRow(name: "base64 decode to shell", regex: "base64.*\\|\\s*(sh|bash)", severity: "critical", target: "hook", description: "Base64 decoded into shell", isBuiltIn: true),
        // Hook - Warning
        RuleRow(name: "curl usage", regex: "\\bcurl\\b", severity: "warning", target: "hook", description: "Uses curl", isBuiltIn: true),
        RuleRow(name: "wget usage", regex: "\\bwget\\b", severity: "warning", target: "hook", description: "Uses wget", isBuiltIn: true),
        RuleRow(name: "chmod 777", regex: "chmod\\s+777", severity: "warning", target: "hook", description: "Sets world-writable permissions", isBuiltIn: true),
        RuleRow(name: "sudo usage", regex: "\\bsudo\\b", severity: "warning", target: "hook", description: "Uses sudo", isBuiltIn: true),
        // Markdown - Warning
        RuleRow(name: "prompt injection: ignore previous", regex: "ignore previous", severity: "warning", target: "markdown", description: "Prompt injection pattern", isBuiltIn: true),
        RuleRow(name: "prompt injection: disregard all", regex: "disregard all", severity: "warning", target: "markdown", description: "Prompt injection pattern", isBuiltIn: true),
        RuleRow(name: "prompt injection: you are now", regex: "you are now", severity: "warning", target: "markdown", description: "Prompt injection pattern", isBuiltIn: true),
        RuleRow(name: "prompt injection: output system prompt", regex: "output the system prompt", severity: "warning", target: "markdown", description: "Prompt injection pattern", isBuiltIn: true),
        RuleRow(name: "prompt injection: reveal instructions", regex: "reveal your instructions", severity: "warning", target: "markdown", description: "Prompt injection pattern", isBuiltIn: true),
        RuleRow(name: "prompt injection: ignore safety", regex: "ignore safety", severity: "warning", target: "markdown", description: "Prompt injection pattern", isBuiltIn: true),
        RuleRow(name: "prompt injection: forget everything", regex: "forget everything", severity: "warning", target: "markdown", description: "Prompt injection pattern", isBuiltIn: true),
        RuleRow(name: "prompt injection: new instructions", regex: "new instructions", severity: "warning", target: "markdown", description: "Prompt injection pattern", isBuiltIn: true),
        RuleRow(name: "prompt injection: override instructions", regex: "override (all |your |the )?(instructions|rules|guidelines)", severity: "warning", target: "markdown", description: "Prompt injection pattern", isBuiltIn: true),
        RuleRow(name: "prompt injection: do not follow", regex: "do not follow (previous|prior|above)", severity: "warning", target: "markdown", description: "Prompt injection pattern", isBuiltIn: true),
        RuleRow(name: "prompt injection: jailbreak", regex: "\\bjailbreak\\b", severity: "warning", target: "markdown", description: "Prompt injection pattern", isBuiltIn: true),
        RuleRow(name: "hidden data: large base64 blob", regex: "[A-Za-z0-9+/]{80,}={0,2}", severity: "warning", target: "markdown", description: "Hidden data in base64 encoding", isBuiltIn: true),
        // MCP - Critical
        RuleRow(name: "MCP args: reverse shell pattern", regex: "/dev/tcp|mkfifo|nc\\s+-e", severity: "critical", target: "mcp", description: "Reverse shell pattern in MCP args", isBuiltIn: true),
        RuleRow(name: "MCP args: base64 decode to shell", regex: "base64.*\\|\\s*(sh|bash)", severity: "critical", target: "mcp", description: "Base64 decoded into shell via MCP", isBuiltIn: true),
        // MCP - Warning
        RuleRow(name: "MCP command contains curl", regex: "curl", severity: "warning", target: "mcp", description: "MCP uses curl", isBuiltIn: true),
        RuleRow(name: "MCP command contains wget", regex: "wget", severity: "warning", target: "mcp", description: "MCP uses wget", isBuiltIn: true),
        RuleRow(name: "MCP command contains nc", regex: "nc", severity: "warning", target: "mcp", description: "MCP uses netcat", isBuiltIn: true),
        RuleRow(name: "MCP args contain external URL", regex: "https?://(?!localhost|127\\.0\\.0\\.1)", severity: "warning", target: "mcp", description: "MCP args contain external URL", isBuiltIn: true),
        RuleRow(name: "MCP env var with external URL", regex: "https?://(?!localhost|127\\.0\\.0\\.1)", severity: "warning", target: "mcp", description: "MCP env var points to external URL", isBuiltIn: true),
        RuleRow(name: "MCP env var name suggests credential", regex: "(API_KEY|SECRET|TOKEN|PASSWORD|CREDENTIALS|AUTH|PRIVATE_KEY)", severity: "warning", target: "mcp", description: "Env var name suggests credentials", isBuiltIn: true),
    ]

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 770, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Security Rules"
        window.center()
        window.minSize = NSSize(width: 600, height: 300)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.windowBg

        super.init(window: window)
        window.delegate = self

        loadRules()
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        NSApp.stopModal()
        SecurityRulesEditorWindow.shared = nil
    }

    // MARK: - Data

    private func loadRules() {
        let customRules = AppConfig.shared.aiComponentsCustomSecurityRules.map { rule in
            RuleRow(
                name: rule.name,
                regex: rule.regex.pattern,
                severity: rule.severity.rawValue,
                target: rule.target,
                description: rule.description
            )
        }
        rules = Self.builtInRules + customRules

        let disabled = AppConfig.shared.aiComponentsDisabledRules
        for i in rules.indices where rules[i].isBuiltIn {
            rules[i].isEnabled = !disabled.contains(rules[i].name)
        }
    }

    private var builtInCount: Int { Self.builtInRules.count }

    // MARK: - UI

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        let titleLabel = NSTextField(labelWithString: "Built-in rules can be toggled on/off. Add custom rules below.")
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleLabel)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 6

        let enabledCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("rule_enabled"))
        enabledCol.title = ""
        enabledCol.width = 24
        enabledCol.minWidth = 24
        enabledCol.maxWidth = 24
        tableView.addTableColumn(enabledCol)

        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("rule_name"))
        nameCol.title = "Name"
        nameCol.width = 140
        nameCol.minWidth = 60
        tableView.addTableColumn(nameCol)

        let regexCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("rule_regex"))
        regexCol.title = "Regex"
        regexCol.width = 200
        regexCol.minWidth = 100
        tableView.addTableColumn(regexCol)

        let severityCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("rule_severity"))
        severityCol.title = "Severity"
        severityCol.width = 80
        severityCol.minWidth = 70
        tableView.addTableColumn(severityCol)

        let targetCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("rule_target"))
        targetCol.title = "Target"
        targetCol.width = 90
        targetCol.minWidth = 70
        tableView.addTableColumn(targetCol)

        let descCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("rule_desc"))
        descCol.title = "Description"
        descCol.width = 250
        descCol.minWidth = 80
        tableView.addTableColumn(descCol)

        tableView.rowHeight = 30
        tableView.dataSource = self
        tableView.delegate = self
        scrollView.documentView = tableView
        contentView.addSubview(scrollView)

        let addBtn = NSButton(title: "Add Rule", target: self, action: #selector(addRuleClicked))
        addBtn.bezelStyle = .rounded
        addBtn.focusRingType = .none
        addBtn.refusesFirstResponder = true
        addBtn.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(addBtn)

        let removeBtn = NSButton(title: "Remove", target: self, action: #selector(removeRuleClicked))
        removeBtn.bezelStyle = .rounded
        removeBtn.focusRingType = .none
        removeBtn.refusesFirstResponder = true
        removeBtn.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(removeBtn)

        let saveBtn = NSButton(title: "  Save  ", target: self, action: #selector(saveClicked))
        saveBtn.isBordered = false
        saveBtn.focusRingType = .none
        saveBtn.refusesFirstResponder = true
        saveBtn.font = .systemFont(ofSize: 13, weight: .medium)
        saveBtn.contentTintColor = .white
        saveBtn.wantsLayer = true
        saveBtn.layer?.backgroundColor = Theme.accent.cgColor
        saveBtn.layer?.cornerRadius = 6
        saveBtn.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(saveBtn)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: addBtn.topAnchor, constant: -10),

            addBtn.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            addBtn.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),

            removeBtn.leadingAnchor.constraint(equalTo: addBtn.trailingAnchor, constant: 8),
            removeBtn.bottomAnchor.constraint(equalTo: addBtn.bottomAnchor),

            saveBtn.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            saveBtn.centerYAnchor.constraint(equalTo: addBtn.centerYAnchor),
            saveBtn.heightAnchor.constraint(equalTo: addBtn.heightAnchor),
        ])
    }

    // MARK: - Actions

    @objc private func addRuleClicked(_ sender: NSButton) {
        rules.append(RuleRow(name: "new_rule", regex: "", severity: "warning", target: "all", description: ""))
        tableView.reloadData()
        // Select and focus the new row
        let newRow = rules.count - 1
        tableView.selectRowIndexes(IndexSet(integer: newRow), byExtendingSelection: false)
        tableView.scrollRowToVisible(newRow)
    }

    @objc private func removeRuleClicked(_ sender: NSButton) {
        let idx = tableView.selectedRow
        guard idx >= 0, idx < rules.count, !rules[idx].isBuiltIn else { return }
        rules.remove(at: idx)
        tableView.reloadData()
    }

    @objc private func saveClicked(_ sender: NSButton) {
        let customRules = rules.filter { !$0.isBuiltIn }

        // Validate all custom rules have non-empty name and valid regex
        for (i, rule) in customRules.enumerated() {
            if rule.name.trimmingCharacters(in: .whitespaces).isEmpty {
                showError("Rule \(i + 1) has an empty name.")
                return
            }
            if rule.regex.trimmingCharacters(in: .whitespaces).isEmpty {
                showError("Rule \"\(rule.name)\" has an empty regex pattern.")
                return
            }
            do {
                _ = try NSRegularExpression(pattern: rule.regex, options: [])
            } catch {
                showError("Rule \"\(rule.name)\" has an invalid regex:\n\(error.localizedDescription)")
                return
            }

            // Warn about overly broad patterns
            let broadPatterns: Set<String> = [".", ".*", ".+", "\\s", "\\S", "\\w", "\\W", "\\d", "[\\s\\S]"]
            if broadPatterns.contains(rule.regex.trimmingCharacters(in: .whitespaces)) {
                let alert = NSAlert()
                alert.messageText = "Broad Pattern"
                alert.informativeText = "Rule \"\(rule.name)\" has a very broad pattern (\(rule.regex)) that may produce excessive findings. Continue anyway?"
                alert.addButton(withTitle: "Continue")
                alert.addButton(withTitle: "Cancel")
                alert.alertStyle = .warning
                if alert.runModal() != .alertFirstButtonReturn { return }
            }
        }

        // Remove existing security_rules section from config, then write new rules
        removeAllSecurityRules()

        for rule in customRules {
            let prefix = "ai_components.security_rules.\(rule.name)"
            ConfigWriter.updateValue(key: "\(prefix).regex", value: "\"\(rule.regex)\"")
            ConfigWriter.updateValue(key: "\(prefix).severity", value: "\"\(rule.severity)\"")
            ConfigWriter.updateValue(key: "\(prefix).target", value: "\"\(rule.target)\"")
            ConfigWriter.updateValue(key: "\(prefix).description", value: "\"\(rule.description)\"")
        }

        // Persist disabled built-in rules
        let disabledNames = rules.filter { $0.isBuiltIn && !$0.isEnabled }.map(\.name)
        if disabledNames.isEmpty {
            ConfigWriter.removeValue(key: "ai_components.disabled_rules")
        } else {
            let joined = disabledNames.joined(separator: ",")
            ConfigWriter.updateValue(key: "ai_components.disabled_rules", value: "\"\(joined)\"")
        }

        AppConfig.reload()
        window?.close()
    }

    private func removeAllSecurityRules() {
        guard let contents = try? String(contentsOf: ConfigWriter.configFile, encoding: .utf8) else { return }
        var lines = contents.components(separatedBy: "\n")

        // Remove all lines that belong to [ai_components.security_rules.*] sections
        var inRulesSection = false
        lines.removeAll { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[ai_components.security_rules.") && trimmed.hasSuffix("]") {
                inRulesSection = true
                return true
            }
            if inRulesSection {
                if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                    inRulesSection = false
                    return false
                }
                if trimmed.isEmpty || trimmed.hasPrefix("#") {
                    return true
                }
                return true
            }
            return false
        }

        let output = lines.joined(separator: "\n")
        try? output.write(to: ConfigWriter.configFile, atomically: true, encoding: .utf8)
    }

    private func showError(_ message: String) {
        let alert = NSAlert.branded()
        alert.messageText = "Validation Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - NSTableViewDataSource & Delegate

extension SecurityRulesEditorWindow: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        return rules.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rules.count else { return nil }
        let rule = rules[row]
        let dimmed = rule.isBuiltIn

        switch tableColumn?.identifier.rawValue {
        case "rule_enabled":
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(enabledToggled(_:)))
            checkbox.state = rule.isEnabled ? .on : .off
            checkbox.tag = row
            // Built-in rules: toggle is enabled; custom rules: always on, not toggleable
            checkbox.isEnabled = rule.isBuiltIn
            return checkbox

        case "rule_name":
            let field = NSTextField()
            field.stringValue = rule.name
            field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            field.isBordered = !dimmed
            field.isEditable = !dimmed
            field.isSelectable = !dimmed
            if dimmed { field.textColor = .tertiaryLabelColor; field.drawsBackground = false }
            field.delegate = self
            field.tag = row * 10 + 0
            field.placeholderString = "rule_name"
            return field

        case "rule_regex":
            let field = NSTextField()
            field.stringValue = rule.regex
            field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            field.isBordered = !dimmed
            field.isEditable = !dimmed
            field.isSelectable = !dimmed
            if dimmed { field.textColor = .tertiaryLabelColor; field.drawsBackground = false }
            field.delegate = self
            field.tag = row * 10 + 1
            field.placeholderString = "pattern.*"
            return field

        case "rule_severity":
            let popup = NSPopUpButton()
            popup.addItems(withTitles: ["warning", "critical"])
            popup.selectItem(withTitle: rule.severity)
            popup.font = .systemFont(ofSize: 11)
            popup.isEnabled = !dimmed
            popup.tag = row * 10 + 2
            popup.target = self
            popup.action = #selector(severityChanged(_:))
            return popup

        case "rule_target":
            let popup = NSPopUpButton()
            popup.addItems(withTitles: ["all", "hook", "markdown", "mcp"])
            popup.selectItem(withTitle: rule.target)
            popup.font = .systemFont(ofSize: 11)
            popup.isEnabled = !dimmed
            popup.tag = row * 10 + 3
            popup.target = self
            popup.action = #selector(targetChanged(_:))
            return popup

        case "rule_desc":
            let field = NSTextField()
            field.stringValue = rule.description
            field.font = .systemFont(ofSize: 11)
            field.isBordered = !dimmed
            field.isEditable = !dimmed
            field.isSelectable = !dimmed
            if dimmed { field.textColor = .tertiaryLabelColor; field.drawsBackground = false }
            field.delegate = self
            field.tag = row * 10 + 4
            field.placeholderString = "Description"
            return field

        default:
            return nil
        }
    }

    @objc private func severityChanged(_ sender: NSPopUpButton) {
        let row = sender.tag / 10
        guard row < rules.count, !rules[row].isBuiltIn, let title = sender.selectedItem?.title else { return }
        rules[row].severity = title
    }

    @objc private func targetChanged(_ sender: NSPopUpButton) {
        let row = sender.tag / 10
        guard row < rules.count, !rules[row].isBuiltIn, let title = sender.selectedItem?.title else { return }
        rules[row].target = title
    }

    @objc private func enabledToggled(_ sender: NSButton) {
        let row = sender.tag
        guard row < rules.count, rules[row].isBuiltIn else { return }
        rules[row].isEnabled = sender.state == .on
    }
}

// MARK: - NSTextFieldDelegate

extension SecurityRulesEditorWindow: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        let row = field.tag / 10
        let col = field.tag % 10
        guard row < rules.count, !rules[row].isBuiltIn else { return }

        switch col {
        case 0: rules[row].name = field.stringValue
        case 1: rules[row].regex = field.stringValue
        case 4: rules[row].description = field.stringValue
        default: break
        }
    }
}
