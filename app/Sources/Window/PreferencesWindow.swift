import AppKit

/// General app-wide preferences window with tabs for Theme, Font, and Keybindings.
class PreferencesWindow: NSWindowController, NSWindowDelegate {

    private static var shared: PreferencesWindow?

    static func show() {
        if let existing = shared {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = PreferencesWindow()
        shared = controller
        controller.showWindow(nil)
    }

    private let tabView = NSTabView()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Preferences"
        window.center()
        window.isReleasedWhenClosed = false
        if AppIcon.image != nil { window.representedURL = nil }

        super.init(window: window)
        window.delegate = self

        setupTabs()
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        Self.shared = nil
    }

    // MARK: - Tabs

    private func setupTabs() {
        tabView.translatesAutoresizingMaskIntoConstraints = false
        window?.contentView?.addSubview(tabView)

        NSLayoutConstraint.activate([
            tabView.leadingAnchor.constraint(equalTo: window!.contentView!.leadingAnchor),
            tabView.trailingAnchor.constraint(equalTo: window!.contentView!.trailingAnchor),
            tabView.topAnchor.constraint(equalTo: window!.contentView!.topAnchor),
            tabView.bottomAnchor.constraint(equalTo: window!.contentView!.bottomAnchor),
        ])

        tabView.addTabViewItem(createAIComponentsTab())
        tabView.addTabViewItem(createKeybindingsTab())
        tabView.addTabViewItem(createVoiceTab())
        tabView.addTabViewItem(createFontTab())
        tabView.addTabViewItem(createThemeTab())
    }

    // MARK: - Theme Tab

    private func createThemeTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "theme")
        item.label = "Theme"

        let view = NSView()
        let config = AppConfig.shared

        let colorDefs: [(String, String, NSColor)] = [
            ("Background", "theme.bg", config.themeBg),
            ("Foreground", "theme.fg", config.themeFg),
            ("Cursor", "theme.cursor", config.themeCursor),
            ("Selection", "theme.selection", config.themeSelection),
            ("Accent", "theme.accent", config.themeAccent),
            ("Tab Bar", "theme.tab_bar_bg", config.themeTabBarBg),
            ("Active Tab", "theme.tab_active_bg", config.themeTabActiveBg),
            ("Status Bar", "theme.status_bar_bg", config.themeStatusBarBg),
        ]

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        grid.columnSpacing = 12
        grid.rowSpacing = 8

        for (label, key, color) in colorDefs {
            let labelField = NSTextField(labelWithString: label)
            labelField.font = .systemFont(ofSize: 13)

            let well = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 24))
            well.color = color
            well.tag = colorDefs.firstIndex(where: { $0.1 == key }) ?? 0
            well.target = self
            well.action = #selector(colorChanged(_:))
            well.identifier = NSUserInterfaceItemIdentifier(key)

            let row = grid.addRow(with: [labelField, well])
            row.height = 30
        }

        view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
        ])

        let note = NSTextField(labelWithString: "Changes are saved to ~/.config/awal/config.toml\nRestart the app for changes to take effect.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(note)
        NSLayoutConstraint.activate([
            note.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            note.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
        ])

        item.view = view
        return item
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        guard let key = sender.identifier?.rawValue else { return }
        let hex = colorToHex(sender.color)
        updateConfigValue(key: key, value: "\"\(hex)\"")
    }

    // MARK: - Font Tab

    private func createFontTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "font")
        item.label = "Font"

        let view = NSView()
        let config = AppConfig.shared

        // Font family
        let familyLabel = NSTextField(labelWithString: "Font Family:")
        familyLabel.font = .systemFont(ofSize: 13)
        familyLabel.translatesAutoresizingMaskIntoConstraints = false

        let familyField = NSTextField(string: config.fontFamily.isEmpty ? "(system monospace)" : config.fontFamily)
        familyField.font = .systemFont(ofSize: 13)
        familyField.translatesAutoresizingMaskIntoConstraints = false
        familyField.identifier = NSUserInterfaceItemIdentifier("font.family")
        familyField.target = self
        familyField.action = #selector(fontFieldChanged(_:))

        // Font size
        let sizeLabel = NSTextField(labelWithString: "Font Size:")
        sizeLabel.font = .systemFont(ofSize: 13)
        sizeLabel.translatesAutoresizingMaskIntoConstraints = false

        let sizeStepper = NSStepper(frame: .zero)
        sizeStepper.minValue = 8
        sizeStepper.maxValue = 36
        sizeStepper.increment = 1
        sizeStepper.doubleValue = Double(config.fontSize)
        sizeStepper.translatesAutoresizingMaskIntoConstraints = false
        sizeStepper.target = self
        sizeStepper.action = #selector(fontSizeChanged(_:))

        let sizeField = NSTextField(string: "\(Int(config.fontSize))")
        sizeField.font = .systemFont(ofSize: 13)
        sizeField.translatesAutoresizingMaskIntoConstraints = false
        sizeField.isEditable = false
        sizeField.identifier = NSUserInterfaceItemIdentifier("fontSizeDisplay")

        // Preview
        let previewLabel = NSTextField(labelWithString: "Preview:")
        previewLabel.font = .systemFont(ofSize: 13)
        previewLabel.translatesAutoresizingMaskIntoConstraints = false

        let previewField = NSTextField(labelWithString: "AaBbCc 0Oo1Il => != ->")
        previewField.font = config.resolvedFont
        previewField.translatesAutoresizingMaskIntoConstraints = false
        previewField.identifier = NSUserInterfaceItemIdentifier("fontPreview")

        for v in [familyLabel, familyField, sizeLabel, sizeField, sizeStepper, previewLabel, previewField] {
            view.addSubview(v)
        }

        NSLayoutConstraint.activate([
            familyLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            familyLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            familyField.leadingAnchor.constraint(equalTo: familyLabel.trailingAnchor, constant: 12),
            familyField.centerYAnchor.constraint(equalTo: familyLabel.centerYAnchor),
            familyField.widthAnchor.constraint(equalToConstant: 200),

            sizeLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            sizeLabel.topAnchor.constraint(equalTo: familyLabel.bottomAnchor, constant: 16),
            sizeField.leadingAnchor.constraint(equalTo: sizeLabel.trailingAnchor, constant: 12),
            sizeField.centerYAnchor.constraint(equalTo: sizeLabel.centerYAnchor),
            sizeField.widthAnchor.constraint(equalToConstant: 40),
            sizeStepper.leadingAnchor.constraint(equalTo: sizeField.trailingAnchor, constant: 4),
            sizeStepper.centerYAnchor.constraint(equalTo: sizeLabel.centerYAnchor),

            previewLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            previewLabel.topAnchor.constraint(equalTo: sizeLabel.bottomAnchor, constant: 24),
            previewField.leadingAnchor.constraint(equalTo: previewLabel.trailingAnchor, constant: 12),
            previewField.centerYAnchor.constraint(equalTo: previewLabel.centerYAnchor),
        ])

        let note = NSTextField(labelWithString: "Changes are saved to ~/.config/awal/config.toml\nRestart the app for changes to take effect.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(note)
        NSLayoutConstraint.activate([
            note.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            note.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
        ])

        item.view = view
        return item
    }

    @objc private func fontFieldChanged(_ sender: NSTextField) {
        let family = sender.stringValue
        updateConfigValue(key: "font.family", value: "\"\(family)\"")
    }

    @objc private func fontSizeChanged(_ sender: NSStepper) {
        let size = Int(sender.doubleValue)
        // Update the display field
        if let sizeField = sender.superview?.subviews
            .compactMap({ $0 as? NSTextField })
            .first(where: { $0.identifier?.rawValue == "fontSizeDisplay" }) {
            sizeField.stringValue = "\(size)"
        }
        updateConfigValue(key: "font.size", value: "\(size)")
    }

    // MARK: - Keybindings Tab

    private func createKeybindingsTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "keybindings")
        item.label = "Keybindings"

        let view = NSView()

        let actions: [(String, String, String)] = [
            ("new_tab", "New Tab", "cmd+t"),
            ("close_tab", "Close Tab", "cmd+w"),
            ("next_tab", "Next Tab", "cmd+shift+]"),
            ("prev_tab", "Previous Tab", "cmd+shift+["),
            ("rename_tab", "Rename Tab", "cmd+shift+r"),
            ("find", "Find", "cmd+f"),
            ("split_right", "Split Right", "cmd+d"),
            ("split_down", "Split Down", "cmd+shift+d"),
            ("close_pane", "Close Pane", "cmd+shift+w"),
            ("next_pane", "Next Pane", "cmd+]"),
            ("prev_pane", "Previous Pane", "cmd+["),
            ("toggle_side_panel", "AI Side Panel", "cmd+shift+i"),
            ("quick_terminal", "Quick Terminal", "ctrl+`"),
            ("settings", "Settings", "cmd+,"),
        ]

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let grid = NSGridView(numberOfColumns: 3, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.columnSpacing = 12
        grid.rowSpacing = 6

        // Header
        let hdrAction = NSTextField(labelWithString: "Action")
        hdrAction.font = .boldSystemFont(ofSize: 12)
        let hdrDefault = NSTextField(labelWithString: "Default")
        hdrDefault.font = .boldSystemFont(ofSize: 12)
        let hdrCustom = NSTextField(labelWithString: "Custom")
        hdrCustom.font = .boldSystemFont(ofSize: 12)
        grid.addRow(with: [hdrAction, hdrDefault, hdrCustom])

        let config = AppConfig.shared
        for (action, label, defaultKey) in actions {
            let actionLabel = NSTextField(labelWithString: label)
            actionLabel.font = .systemFont(ofSize: 13)

            let defaultLabel = NSTextField(labelWithString: defaultKey)
            defaultLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            defaultLabel.textColor = .secondaryLabelColor

            let customField = NSTextField(string: config.keybindings[action] ?? "")
            customField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            customField.placeholderString = defaultKey
            customField.identifier = NSUserInterfaceItemIdentifier("kb.\(action)")
            customField.target = self
            customField.action = #selector(keybindingChanged(_:))

            let row = grid.addRow(with: [actionLabel, defaultLabel, customField])
            row.height = 26
        }

        grid.column(at: 2).width = 140

        scrollView.documentView = grid
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
        ])

        item.view = view
        return item
    }

    @objc private func keybindingChanged(_ sender: NSTextField) {
        guard let id = sender.identifier?.rawValue, id.hasPrefix("kb.") else { return }
        let action = String(id.dropFirst(3))
        let value = sender.stringValue.trimmingCharacters(in: .whitespaces)
        if value.isEmpty {
            removeConfigValue(key: "keybindings.\(action)")
        } else {
            updateConfigValue(key: "keybindings.\(action)", value: "\"\(value)\"")
        }
    }

    // MARK: - Voice Tab

    private func createVoiceTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "voice")
        item.label = "Voice"

        let view = NSView()
        let config = AppConfig.shared

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.columnSpacing = 12
        grid.rowSpacing = 10

        // Enabled toggle
        let enabledLabel = NSTextField(labelWithString: "Enabled")
        enabledLabel.font = .systemFont(ofSize: 13)
        let enabledCheck = NSButton(checkboxWithTitle: "", target: self, action: #selector(voiceEnabledChanged(_:)))
        enabledCheck.state = config.voiceEnabled ? .on : .off
        grid.addRow(with: [enabledLabel, enabledCheck])

        // Mode picker
        let modeLabel = NSTextField(labelWithString: "Mode")
        modeLabel.font = .systemFont(ofSize: 13)
        let modePicker = NSPopUpButton(frame: .zero, pullsDown: false)
        modePicker.addItems(withTitles: ["Push-to-Talk", "Continuous", "Wake Word"])
        switch config.voiceMode {
        case "continuous": modePicker.selectItem(at: 1)
        case "wake_word": modePicker.selectItem(at: 2)
        default: modePicker.selectItem(at: 0)
        }
        modePicker.target = self
        modePicker.action = #selector(voiceModeChanged(_:))
        grid.addRow(with: [modeLabel, modePicker])

        // Whisper model
        let modelLabel = NSTextField(labelWithString: "Whisper Model")
        modelLabel.font = .systemFont(ofSize: 13)
        let modelPicker = NSPopUpButton(frame: .zero, pullsDown: false)
        modelPicker.addItems(withTitles: ModelDownloadManager.availableModels)
        if let idx = ModelDownloadManager.availableModels.firstIndex(of: config.voiceWhisperModel) {
            modelPicker.selectItem(at: idx)
        }
        modelPicker.target = self
        modelPicker.action = #selector(voiceModelChanged(_:))
        grid.addRow(with: [modelLabel, modelPicker])

        // VAD threshold slider
        let vadLabel = NSTextField(labelWithString: "VAD Threshold")
        vadLabel.font = .systemFont(ofSize: 13)
        let vadSlider = NSSlider(value: Double(config.voiceVadThreshold), minValue: 0.005, maxValue: 0.1, target: self, action: #selector(voiceVadChanged(_:)))
        vadSlider.numberOfTickMarks = 10
        grid.addRow(with: [vadLabel, vadSlider])

        // PTT hotkey
        let hotkeyLabel = NSTextField(labelWithString: "Push-to-Talk Key")
        hotkeyLabel.font = .systemFont(ofSize: 13)
        let hotkeyField = NSTextField(string: config.voicePushToTalkKey)
        hotkeyField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        hotkeyField.identifier = NSUserInterfaceItemIdentifier("voice.push_to_talk_key")
        hotkeyField.target = self
        hotkeyField.action = #selector(voiceFieldChanged(_:))
        grid.addRow(with: [hotkeyLabel, hotkeyField])

        // Wake word
        let wakeLabel = NSTextField(labelWithString: "Wake Word")
        wakeLabel.font = .systemFont(ofSize: 13)
        let wakeField = NSTextField(string: config.voiceWakeWord)
        wakeField.font = .systemFont(ofSize: 13)
        wakeField.identifier = NSUserInterfaceItemIdentifier("voice.wake_word")
        wakeField.target = self
        wakeField.action = #selector(voiceFieldChanged(_:))
        grid.addRow(with: [wakeLabel, wakeField])

        // Auto-enter
        let enterLabel = NSTextField(labelWithString: "Auto-Enter")
        enterLabel.font = .systemFont(ofSize: 13)
        let enterCheck = NSButton(checkboxWithTitle: "Append newline after dictation", target: self, action: #selector(voiceAutoEnterChanged(_:)))
        enterCheck.state = config.voiceDictationAutoEnter ? .on : .off
        grid.addRow(with: [enterLabel, enterCheck])

        // Auto-space
        let spaceLabel = NSTextField(labelWithString: "Auto-Space")
        spaceLabel.font = .systemFont(ofSize: 13)
        let spaceCheck = NSButton(checkboxWithTitle: "Add space between segments", target: self, action: #selector(voiceAutoSpaceChanged(_:)))
        spaceCheck.state = config.voiceDictationAutoSpace ? .on : .off
        grid.addRow(with: [spaceLabel, spaceCheck])

        grid.column(at: 1).width = 200
        view.addSubview(grid)

        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
        ])

        let note = NSTextField(labelWithString: "Changes are saved to ~/.config/awal/config.toml\nRestart the app for changes to take effect.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(note)
        NSLayoutConstraint.activate([
            note.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            note.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
        ])

        item.view = view
        return item
    }

    @objc private func voiceEnabledChanged(_ sender: NSButton) {
        updateConfigValue(key: "voice.enabled", value: sender.state == .on ? "true" : "false")
    }

    @objc private func voiceModeChanged(_ sender: NSPopUpButton) {
        let modes = ["push_to_talk", "continuous", "wake_word"]
        let value = modes[sender.indexOfSelectedItem]
        updateConfigValue(key: "voice.mode", value: "\"\(value)\"")
    }

    @objc private func voiceModelChanged(_ sender: NSPopUpButton) {
        let model = ModelDownloadManager.availableModels[sender.indexOfSelectedItem]
        updateConfigValue(key: "voice.whisper_model", value: "\"\(model)\"")
    }

    @objc private func voiceVadChanged(_ sender: NSSlider) {
        updateConfigValue(key: "voice.vad_threshold", value: String(format: "%.3f", sender.doubleValue))
    }

    @objc private func voiceFieldChanged(_ sender: NSTextField) {
        guard let key = sender.identifier?.rawValue else { return }
        updateConfigValue(key: key, value: "\"\(sender.stringValue)\"")
    }

    @objc private func voiceAutoEnterChanged(_ sender: NSButton) {
        updateConfigValue(key: "voice.dictation_auto_enter", value: sender.state == .on ? "true" : "false")
    }

    @objc private func voiceAutoSpaceChanged(_ sender: NSButton) {
        updateConfigValue(key: "voice.dictation_auto_space", value: sender.state == .on ? "true" : "false")
    }

    // MARK: - AI Components Tab

    private var registryTableView: NSTableView?
    private var aiComponentsStatusLabel: NSTextField?

    private func createAIComponentsTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "ai_components")
        item.label = "AI Components"

        let view = NSView()
        let config = AppConfig.shared

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.columnSpacing = 12
        grid.rowSpacing = 10

        // Enable toggle
        let enabledLabel = NSTextField(labelWithString: "Enable AI Components")
        enabledLabel.font = .systemFont(ofSize: 13)
        let enabledCheck = NSButton(checkboxWithTitle: "", target: self, action: #selector(aiComponentsEnabledChanged(_:)))
        enabledCheck.state = config.aiComponentsEnabled ? .on : .off
        grid.addRow(with: [enabledLabel, enabledCheck])

        // Auto-detect toggle
        let detectLabel = NSTextField(labelWithString: "Auto-detect project type")
        detectLabel.font = .systemFont(ofSize: 13)
        let detectCheck = NSButton(checkboxWithTitle: "", target: self, action: #selector(aiComponentsAutoDetectChanged(_:)))
        detectCheck.state = config.aiComponentsAutoDetect ? .on : .off
        grid.addRow(with: [detectLabel, detectCheck])

        view.addSubview(grid)

        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
        ])

        // Registry section header
        let regHeader = NSTextField(labelWithString: "Registries")
        regHeader.font = .boldSystemFont(ofSize: 12)
        regHeader.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(regHeader)

        // Registry table
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let table = NSTableView()
        table.headerView = NSTableHeaderView()
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false

        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameCol.title = "Name"
        nameCol.width = 100
        table.addTableColumn(nameCol)

        let urlCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("url"))
        urlCol.title = "URL"
        urlCol.width = 280
        table.addTableColumn(urlCol)

        let branchCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("branch"))
        branchCol.title = "Branch"
        branchCol.width = 60
        table.addTableColumn(branchCol)

        table.delegate = self
        table.dataSource = self
        registryTableView = table

        scrollView.documentView = table
        view.addSubview(scrollView)

        // Buttons
        let addBtn = NSButton(title: "+ Add Registry", target: self, action: #selector(addRegistryClicked(_:)))
        addBtn.translatesAutoresizingMaskIntoConstraints = false
        addBtn.bezelStyle = .rounded
        view.addSubview(addBtn)

        let removeBtn = NSButton(title: "- Remove", target: self, action: #selector(removeRegistryClicked(_:)))
        removeBtn.translatesAutoresizingMaskIntoConstraints = false
        removeBtn.bezelStyle = .rounded
        view.addSubview(removeBtn)

        let syncBtn = NSButton(title: "Sync Now", target: self, action: #selector(syncRegistriesClicked(_:)))
        syncBtn.translatesAutoresizingMaskIntoConstraints = false
        syncBtn.bezelStyle = .rounded
        view.addSubview(syncBtn)

        // Sync status
        let statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.isEditable = false
        statusLabel.isBordered = false
        statusLabel.drawsBackground = false
        view.addSubview(statusLabel)
        aiComponentsStatusLabel = statusLabel
        updateAIComponentsStatus()

        // Sync mode + interval
        let syncModeLabel = NSTextField(labelWithString: "Sync mode:")
        syncModeLabel.font = .systemFont(ofSize: 12)
        syncModeLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(syncModeLabel)

        let syncModePicker = NSPopUpButton(frame: .zero, pullsDown: false)
        syncModePicker.addItems(withTitles: ["Auto", "Manual"])
        syncModePicker.selectItem(at: config.aiComponentsAutoSync ? 0 : 1)
        syncModePicker.translatesAutoresizingMaskIntoConstraints = false
        syncModePicker.target = self
        syncModePicker.action = #selector(aiComponentsSyncModeChanged(_:))
        view.addSubview(syncModePicker)

        let intervalLabel = NSTextField(labelWithString: "Interval:")
        intervalLabel.font = .systemFont(ofSize: 12)
        intervalLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(intervalLabel)

        let intervalField = NSTextField(string: "\(config.aiComponentsSyncInterval)")
        intervalField.font = .systemFont(ofSize: 12)
        intervalField.translatesAutoresizingMaskIntoConstraints = false
        intervalField.identifier = NSUserInterfaceItemIdentifier("ai_components.sync_interval")
        intervalField.target = self
        intervalField.action = #selector(aiComponentsIntervalChanged(_:))
        view.addSubview(intervalField)

        let secLabel = NSTextField(labelWithString: "sec")
        secLabel.font = .systemFont(ofSize: 12)
        secLabel.textColor = .secondaryLabelColor
        secLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(secLabel)

        NSLayoutConstraint.activate([
            regHeader.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            regHeader.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 16),

            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            scrollView.topAnchor.constraint(equalTo: regHeader.bottomAnchor, constant: 8),
            scrollView.heightAnchor.constraint(equalToConstant: 90),

            addBtn.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            addBtn.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 8),

            removeBtn.leadingAnchor.constraint(equalTo: addBtn.trailingAnchor, constant: 8),
            removeBtn.centerYAnchor.constraint(equalTo: addBtn.centerYAnchor),

            syncBtn.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            syncBtn.centerYAnchor.constraint(equalTo: addBtn.centerYAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            statusLabel.topAnchor.constraint(equalTo: addBtn.bottomAnchor, constant: 12),

            syncModeLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            syncModeLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            syncModePicker.leadingAnchor.constraint(equalTo: syncModeLabel.trailingAnchor, constant: 6),
            syncModePicker.centerYAnchor.constraint(equalTo: syncModeLabel.centerYAnchor),

            intervalLabel.leadingAnchor.constraint(equalTo: syncModePicker.trailingAnchor, constant: 16),
            intervalLabel.centerYAnchor.constraint(equalTo: syncModeLabel.centerYAnchor),
            intervalField.leadingAnchor.constraint(equalTo: intervalLabel.trailingAnchor, constant: 6),
            intervalField.centerYAnchor.constraint(equalTo: syncModeLabel.centerYAnchor),
            intervalField.widthAnchor.constraint(equalToConstant: 60),
            secLabel.leadingAnchor.constraint(equalTo: intervalField.trailingAnchor, constant: 4),
            secLabel.centerYAnchor.constraint(equalTo: syncModeLabel.centerYAnchor),
        ])

        let note = NSTextField(labelWithString: "Changes are saved to ~/.config/awal/config.toml")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(note)
        NSLayoutConstraint.activate([
            note.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            note.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
        ])

        item.view = view
        return item
    }

    @objc private func aiComponentsEnabledChanged(_ sender: NSButton) {
        updateConfigValue(key: "ai_components.enabled", value: sender.state == .on ? "true" : "false")
    }

    @objc private func aiComponentsAutoDetectChanged(_ sender: NSButton) {
        updateConfigValue(key: "ai_components.auto_detect", value: sender.state == .on ? "true" : "false")
    }

    @objc private func aiComponentsSyncModeChanged(_ sender: NSPopUpButton) {
        let auto = sender.indexOfSelectedItem == 0
        updateConfigValue(key: "ai_components.auto_sync", value: auto ? "true" : "false")
    }

    @objc private func aiComponentsIntervalChanged(_ sender: NSTextField) {
        let value = sender.stringValue.trimmingCharacters(in: .whitespaces)
        if let _ = Int(value) {
            updateConfigValue(key: "ai_components.sync_interval", value: value)
        }
    }

    @objc private func addRegistryClicked(_ sender: NSButton) {
        let alert = NSAlert()
        alert.messageText = "Add AI Component Registry"
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 90))

        let nameLabel = NSTextField(labelWithString: "Name:")
        nameLabel.frame = NSRect(x: 0, y: 64, width: 50, height: 20)
        container.addSubview(nameLabel)

        let nameField = NSTextField(frame: NSRect(x: 55, y: 62, width: 240, height: 22))
        nameField.placeholderString = "team-components"
        container.addSubview(nameField)

        let urlLabel = NSTextField(labelWithString: "URL:")
        urlLabel.frame = NSRect(x: 0, y: 34, width: 50, height: 20)
        container.addSubview(urlLabel)

        let urlField = NSTextField(frame: NSRect(x: 55, y: 32, width: 240, height: 22))
        urlField.placeholderString = "https://github.com/org/components.git"
        container.addSubview(urlField)

        let branchLabel = NSTextField(labelWithString: "Branch:")
        branchLabel.frame = NSRect(x: 0, y: 4, width: 50, height: 20)
        container.addSubview(branchLabel)

        let branchField = NSTextField(frame: NSRect(x: 55, y: 2, width: 240, height: 22))
        branchField.stringValue = "main"
        container.addSubview(branchField)

        alert.accessoryView = container

        guard let w = window else { return }
        alert.beginSheetModal(for: w) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
            let url = urlField.stringValue.trimmingCharacters(in: .whitespaces)
            let branch = branchField.stringValue.trimmingCharacters(in: .whitespaces)

            guard !name.isEmpty, !url.isEmpty else { return }

            self?.updateConfigValue(key: "ai_components.registry.\(name).url", value: "\"\(url)\"")
            self?.updateConfigValue(key: "ai_components.registry.\(name).branch", value: "\"\(branch.isEmpty ? "main" : branch)\"")

            // Trigger initial clone
            RegistryManager.shared.syncOne(name: name, url: url, branch: branch.isEmpty ? "main" : branch)

            self?.registryTableView?.reloadData()
            self?.updateAIComponentsStatus()
        }
    }

    @objc private func removeRegistryClicked(_ sender: NSButton) {
        guard let table = registryTableView, table.selectedRow >= 0 else { return }
        let config = AppConfig.shared
        let idx = table.selectedRow
        guard idx < config.aiComponentRegistries.count else { return }

        let reg = config.aiComponentRegistries[idx]
        removeConfigValue(key: "ai_components.registry.\(reg.name).url")
        removeConfigValue(key: "ai_components.registry.\(reg.name).branch")
        RegistryManager.shared.removeRegistry(name: reg.name)

        table.reloadData()
        updateAIComponentsStatus()
    }

    @objc private func syncRegistriesClicked(_ sender: NSButton) {
        let config = AppConfig.shared
        aiComponentsStatusLabel?.stringValue = "Syncing..."

        RegistryManager.shared.syncAll(registries: config.aiComponentRegistries, force: true) { [weak self] in
            self?.updateAIComponentsStatus()
        }
    }

    private func updateAIComponentsStatus() {
        if let lastSync = RegistryManager.shared.lastSyncTimeAny() {
            let elapsed = Int(Date().timeIntervalSince(lastSync))
            if elapsed < 60 {
                aiComponentsStatusLabel?.stringValue = "Last synced: \(elapsed) seconds ago"
            } else if elapsed < 3600 {
                aiComponentsStatusLabel?.stringValue = "Last synced: \(elapsed / 60) minutes ago"
            } else {
                aiComponentsStatusLabel?.stringValue = "Last synced: \(elapsed / 3600) hours ago"
            }
        } else {
            aiComponentsStatusLabel?.stringValue = "Not synced yet"
        }
    }

    // MARK: - Config File Helpers

    private static let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/awal")
    private static let configFile = configDir.appendingPathComponent("config.toml")

    /// Update or insert a key in the TOML config file.
    private func updateConfigValue(key: String, value: String) {
        try? FileManager.default.createDirectory(at: Self.configDir, withIntermediateDirectories: true)

        let contents = (try? String(contentsOf: Self.configFile, encoding: .utf8)) ?? ""
        var lines = contents.components(separatedBy: "\n")

        // Parse dotted key into section + field
        let parts = key.split(separator: ".", maxSplits: 1)
        let section = parts.count > 1 ? String(parts[0]) : ""
        let field = parts.count > 1 ? String(parts[1]) : key

        // Find the section and update or insert
        var sectionIdx: Int? = nil
        var fieldIdx: Int? = nil

        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "[\(section)]" {
                sectionIdx = i
            }
            if sectionIdx != nil && (trimmed.hasPrefix("\(field) =") || trimmed.hasPrefix("\(field)=")) {
                fieldIdx = i
                break
            }
            // Stop if we hit another section
            if sectionIdx != nil && i > sectionIdx! && trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                break
            }
        }

        if let fi = fieldIdx {
            lines[fi] = "\(field) = \(value)"
        } else if let si = sectionIdx {
            lines.insert("\(field) = \(value)", at: si + 1)
        } else {
            // Add new section
            if !lines.last!.isEmpty { lines.append("") }
            lines.append("[\(section)]")
            lines.append("\(field) = \(value)")
        }

        let output = lines.joined(separator: "\n")
        try? output.write(to: Self.configFile, atomically: true, encoding: .utf8)
    }

    private func removeConfigValue(key: String) {
        guard let contents = try? String(contentsOf: Self.configFile, encoding: .utf8) else { return }
        let parts = key.split(separator: ".", maxSplits: 1)
        let field = parts.count > 1 ? String(parts[1]) : key

        var lines = contents.components(separatedBy: "\n")
        lines.removeAll { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("\(field) =") || trimmed.hasPrefix("\(field)=")
        }
        let output = lines.joined(separator: "\n")
        try? output.write(to: Self.configFile, atomically: true, encoding: .utf8)
    }

    private func colorToHex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        let r = Int(c.redComponent * 255)
        let g = Int(c.greenComponent * 255)
        let b = Int(c.blueComponent * 255)
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}

// MARK: - Registry Table View

extension PreferencesWindow: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        AppConfig.shared.aiComponentRegistries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let registries = AppConfig.shared.aiComponentRegistries
        guard row < registries.count else { return nil }
        let reg = registries[row]

        let cell = NSTextField(labelWithString: "")
        cell.font = .systemFont(ofSize: 12)
        cell.lineBreakMode = .byTruncatingTail

        switch tableColumn?.identifier.rawValue {
        case "name":
            cell.stringValue = reg.name
        case "url":
            cell.stringValue = reg.url
        case "branch":
            cell.stringValue = reg.branch
        default:
            break
        }

        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        22
    }
}
